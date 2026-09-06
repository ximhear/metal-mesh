import MeshCore
import CoreGraphics
import Metal
import MetalKit

/// 메시렛 메시의 GPU 버퍼 묶음 + 재질 인자 버퍼 + 텍스처
struct GPUMesh {
    let vertices: MTLBuffer
    let meshlets: MTLBuffer
    let meshletVertices: MTLBuffer
    let meshletTriangles: MTLBuffer
    /// `Material` 배열. 텍스처는 gpuResourceID로 참조 (Metal 3 인자 버퍼 tier 2)
    let materials: MTLBuffer
    /// fragment에서 useResources로 상주시켜야 하는 텍스처 (플레이스홀더 포함)
    let textures: [MTLTexture]
    let meshletCount: Int
    let vertexCount: Int
    let triangleCount: Int
    let materialCount: Int
    let textureCount: Int

    enum Error: LocalizedError {
        case empty
        case allocationFailed(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "메시렛이 없습니다."
            case .allocationFailed(let name): return "GPU 버퍼를 만들 수 없습니다: \(name)"
            }
        }
    }

    init(device: MTLDevice, mesh: MeshletMesh, materials materialData: [MaterialData]) throws {
        guard !mesh.meshlets.isEmpty, !mesh.vertices.isEmpty else { throw Error.empty }
        func make<T>(_ array: [T], _ name: String) throws -> MTLBuffer {
            let length = array.count * MemoryLayout<T>.stride
            guard let buffer = array.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: length, options: .storageModeShared)
            }) else { throw Error.allocationFailed(name) }
            buffer.label = name
            return buffer
        }
        vertices = try make(mesh.vertices, "vertices")
        meshlets = try make(mesh.meshlets, "meshlets")
        meshletVertices = try make(mesh.meshletVertices, "meshletVertices")
        // uchar 배열은 4바이트 정렬 보장을 위해 패딩
        var triangles = mesh.meshletTriangles
        while triangles.count % 4 != 0 { triangles.append(0) }
        meshletTriangles = try make(triangles, "meshletTriangles")
        meshletCount = mesh.meshlets.count
        vertexCount = mesh.vertices.count
        triangleCount = mesh.triangleCount

        // 재질 → 텍스처 업로드 + 인자 버퍼. 같은 CGImage는 한 번만 올린다(glTF의 metallicRoughness 공유 등).
        let loader = MTKTextureLoader(device: device)
        let placeholder = try Self.makePlaceholderTexture(device: device)
        var textures: [MTLTexture] = [placeholder]
        var cache: [ObjectIdentifier: MTLTexture] = [:]
        func upload(_ image: CGImage?, srgb: Bool, label: String) -> MTLTexture? {
            guard let image else { return nil }
            if let cached = cache[ObjectIdentifier(image)] { return cached }
            guard let loaded = try? loader.newTexture(cgImage: Self.normalizedRGBA(image), options: [
                .SRGB: srgb,
                .generateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ]) else { return nil }
            loaded.label = label
            cache[ObjectIdentifier(image)] = loaded
            textures.append(loaded)
            return loaded
        }
        var gpuMaterials: [Material] = []
        let sourceMaterials = materialData.isEmpty ? [MaterialData.default] : materialData
        for material in sourceMaterials {
            var m = Material()
            m.baseColorFactor = material.baseColorFactor
            m.metallicFactor = material.metallicFactor
            m.roughnessFactor = material.roughnessFactor
            m.normalScale = material.normalScale
            m.roughnessChannel = UInt32(material.roughnessChannel)
            m.metallicChannel = UInt32(material.metallicChannel)
            var flags: UInt32 = 0
            var base = placeholder, normal = placeholder, rough = placeholder, metal = placeholder
            if let t = upload(material.baseColorImage, srgb: true, label: material.name + ".baseColor") { base = t; flags |= MATERIAL_HAS_BASE_COLOR }
            if let t = upload(material.normalImage, srgb: false, label: material.name + ".normal") { normal = t; flags |= MATERIAL_HAS_NORMAL }
            if let t = upload(material.roughnessImage, srgb: false, label: material.name + ".roughness") { rough = t; flags |= MATERIAL_HAS_ROUGHNESS }
            if let t = upload(material.metallicImage, srgb: false, label: material.name + ".metallic") { metal = t; flags |= MATERIAL_HAS_METALLIC }
            m.flags = flags
            m.baseColorTexture._impl = base.gpuResourceID._impl
            m.normalTexture._impl = normal.gpuResourceID._impl
            m.roughnessTexture._impl = rough.gpuResourceID._impl
            m.metallicTexture._impl = metal.gpuResourceID._impl
            gpuMaterials.append(m)
        }
        materials = try make(gpuMaterials, "materials")
        self.textures = textures
        materialCount = gpuMaterials.count
        textureCount = textures.count - 1
    }

    /// MTKTextureLoader는 인덱스 컬러(팔레트) PNG나 그레이스케일 등 일부 CGImage를 디코딩하지 못한다("Image decoding failed").
    /// 32bpp RGB가 아니면 sRGB RGBA8로 다시 그려서 넘긴다.
    static func normalizedRGBA(_ image: CGImage) -> CGImage {
        let isRGB = image.colorSpace?.model == .rgb
        if image.bitsPerPixel == 32 && image.bitsPerComponent == 8 && isRGB { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func makePlaceholderTexture(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { throw Error.allocationFailed("placeholder") }
        var white: UInt32 = 0xFFFF_FFFF
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        texture.label = "placeholder-white"
        return texture
    }
}
