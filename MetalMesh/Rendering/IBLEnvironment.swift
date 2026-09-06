import CoreGraphics
import Foundation
import ImageIO
import Metal
import MeshCore

/// HDRI로부터 IBL 텍스처(조도 큐브맵, 프리필터 스펙큘러 큐브맵, BRDF LUT)를 GPU에서 미리 계산한다.
/// 디바이스당 한 번 만들고 공유한다.
final class IBLEnvironment {
    let irradiance: MTLTexture
    let specular: MTLTexture
    let brdfLUT: MTLTexture
    var specularMipCount: Int { specular.mipmapLevelCount }

    static let environmentSize = 256
    static let irradianceSize = 32
    static let brdfSize = 128

    enum Error: LocalizedError {
        case notFound, decodeFailed, gpu(String)
        var errorDescription: String? {
            switch self {
            case .notFound: return "환경맵 파일이 없습니다."
            case .decodeFailed: return "HDR 이미지를 읽을 수 없습니다."
            case .gpu(let what): return "IBL 생성 실패: \(what)"
            }
        }
    }

    private static var shared: [ObjectIdentifier: IBLEnvironment] = [:]
    private static let lock = NSLock()

    /// 번들의 기본 HDRI로 만든 환경. 실패하면 nil (IBL 없이 렌더).
    static func `default`(device: MTLDevice) -> IBLEnvironment? {
        lock.lock(); defer { lock.unlock() }
        if let cached = shared[ObjectIdentifier(device)] { return cached }
        guard let url = Bundle.main.url(forResource: "studio_small_09_1k", withExtension: "hdr", subdirectory: "Environment")
            ?? Bundle.main.url(forResource: "studio_small_09_1k", withExtension: "hdr") else { return nil }
        guard let env = try? IBLEnvironment(device: device, hdrURL: url) else { return nil }
        shared[ObjectIdentifier(device)] = env
        return env
    }

    init(device: MTLDevice, hdrURL: URL) throws {
        let equirect = try Self.loadEquirect(device: device, url: hdrURL)
        guard let library = device.makeDefaultLibrary(), let queue = device.makeCommandQueue() else { throw Error.gpu("library") }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw Error.gpu(name) }
            return try device.makeComputePipelineState(function: f)
        }
        let toCube = try pipeline("iblEquirectToCube")
        let irradiancePipeline = try pipeline("iblIrradiance")
        let prefilterPipeline = try pipeline("iblPrefilterSpecular")
        let lutPipeline = try pipeline("iblBRDFLUT")

        func cubeDescriptor(size: Int, mipmapped: Bool) -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: mipmapped)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return d
        }
        guard let envCube = device.makeTexture(descriptor: cubeDescriptor(size: Self.environmentSize, mipmapped: true)),
              let irradiance = device.makeTexture(descriptor: cubeDescriptor(size: Self.irradianceSize, mipmapped: false)),
              let specular = device.makeTexture(descriptor: cubeDescriptor(size: Self.environmentSize, mipmapped: true)) else {
            throw Error.gpu("cube textures")
        }
        let lutDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: Self.brdfSize, height: Self.brdfSize, mipmapped: false)
        lutDesc.usage = [.shaderRead, .shaderWrite]
        lutDesc.storageMode = .private
        guard let brdfLUT = device.makeTexture(descriptor: lutDesc) else { throw Error.gpu("lut") }
        envCube.label = "IBL env"; irradiance.label = "IBL irradiance"; specular.label = "IBL specular"; brdfLUT.label = "IBL brdf"

        guard let commandBuffer = queue.makeCommandBuffer() else { throw Error.gpu("command buffer") }
        commandBuffer.label = "IBL precompute"

        func dispatchCube(_ encoder: MTLComputeCommandEncoder, size: Int) {
            encoder.dispatchThreadgroups(MTLSize(width: (size + 7) / 8, height: (size + 7) / 8, depth: 6),
                                         threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        // 1) 등장방형 → 큐브
        if let e = commandBuffer.makeComputeCommandEncoder() {
            e.label = "equirect→cube"
            e.setComputePipelineState(toCube)
            e.setTexture(equirect, index: 0)
            e.setTexture(envCube, index: 1)
            dispatchCube(e, size: Self.environmentSize)
            e.endEncoding()
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: envCube)
            blit.endEncoding()
        }
        // 2) 조도
        if let e = commandBuffer.makeComputeCommandEncoder() {
            e.label = "irradiance"
            e.setComputePipelineState(irradiancePipeline)
            e.setTexture(envCube, index: 0)
            e.setTexture(irradiance, index: 1)
            dispatchCube(e, size: Self.irradianceSize)
            e.endEncoding()
        }
        // 3) 프리필터 스펙큘러 (밉별 러프니스)
        let mipCount = specular.mipmapLevelCount
        for level in 0..<mipCount {
            guard let view = specular.makeTextureView(pixelFormat: .rgba16Float, textureType: .typeCube, levels: level..<(level + 1), slices: 0..<6),
                  let e = commandBuffer.makeComputeCommandEncoder() else { continue }
            e.label = "prefilter mip \(level)"
            var roughness = Float(level) / Float(max(mipCount - 1, 1))
            var envSize = Float(Self.environmentSize)
            e.setComputePipelineState(prefilterPipeline)
            e.setTexture(envCube, index: 0)
            e.setTexture(view, index: 1)
            e.setBytes(&roughness, length: 4, index: 0)
            e.setBytes(&envSize, length: 4, index: 1)
            dispatchCube(e, size: max(Self.environmentSize >> level, 1))
            e.endEncoding()
        }
        // 4) BRDF LUT
        if let e = commandBuffer.makeComputeCommandEncoder() {
            e.label = "brdf lut"
            e.setComputePipelineState(lutPipeline)
            e.setTexture(brdfLUT, index: 0)
            e.dispatchThreadgroups(MTLSize(width: Self.brdfSize / 8, height: Self.brdfSize / 8, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw Error.gpu(error.localizedDescription) }

        self.irradiance = irradiance
        self.specular = specular
        self.brdfLUT = brdfLUT
    }

    /// Radiance HDR/EXR → rgba32Float 텍스처 (선형)
    private static func loadEquirect(device: MTLDevice, url: URL) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Error.decodeFailed }
        let width = image.width, height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw Error.decodeFailed }
        let info = CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16,
                                      space: colorSpace, bitmapInfo: info), let data = context.data else { throw Error.decodeFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw Error.gpu("equirect") }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 16)
        texture.label = "HDRI equirect"
        return texture
    }
}
