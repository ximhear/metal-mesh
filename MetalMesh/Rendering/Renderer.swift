import MeshCore
import Foundation
import Metal
import MetalKit
import simd

/// 메시 셰이더 파이프라인으로 메시렛 메시 하나를 그린다. 모든 메서드는 메인 스레드에서 호출한다.
final class Renderer: NSObject, MTKViewDelegate {
    enum Error: LocalizedError {
        case libraryNotFound
        case functionNotFound(String)
        case meshShadersUnsupported
        var errorDescription: String? {
            switch self {
            case .libraryNotFound: return "Metal 라이브러리를 찾을 수 없습니다."
            case .functionNotFound(let n): return "셰이더 함수가 없습니다: \(n)"
            case .meshShadersUnsupported: return "이 GPU는 메시 셰이더를 지원하지 않습니다."
            }
        }
    }

    static let maxFramesInFlight = 3
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    static let clearColor = MTLClearColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)

    let device: MTLDevice
    let camera = OrbitCamera()
    var settings = RenderSettings()
    /// 통계가 갱신될 때 메인 스레드에서 호출된다 (약 4회/초)
    var onStats: ((RenderStats) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let hizCopyPipeline: MTLComputePipelineState
    private let hizDownsamplePipeline: MTLComputePipelineState
    private let gpuMesh: GPUMesh
    private let uniformBuffers: [MTLBuffer]
    private let statsBuffers: [MTLBuffer]
    /// 메시렛별 지난 프레임 가시성 (uint). 오클루전 2패스에서 GPU가 읽고 쓴다.
    private let visibilityBuffer: MTLBuffer
    private var hizTexture: MTLTexture?
    private var hizLevelViews: [MTLTexture] = []
    /// IBL 환경 (없으면 방향광 폴백)
    let environment: IBLEnvironment?
    private let inflight = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    private var frameIndex = 0
    private var lastStatsReport = Date.distantPast

    private(set) var stats = RenderStats()

    init(device: MTLDevice, mesh: MeshletMesh, materials: [MaterialData] = [.default]) throws {
        guard device.supportsFamily(.metal3), device.argumentBuffersSupport == .tier2 else {
            throw Error.meshShadersUnsupported
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Error.meshShadersUnsupported }
        commandQueue = queue
        gpuMesh = try GPUMesh(device: device, mesh: mesh, materials: materials)
        environment = IBLEnvironment.default(device: device)

        guard let library = device.makeDefaultLibrary() else { throw Error.libraryNotFound }
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw Error.functionNotFound(name) }
            return f
        }
        let descriptor = MTLMeshRenderPipelineDescriptor()
        descriptor.label = "MeshletPipeline"
        descriptor.objectFunction = try function("objectMain")
        descriptor.meshFunction = try function("meshMain")
        descriptor.fragmentFunction = try function("fragmentMain")
        descriptor.payloadMemoryLength = MemoryLayout<MeshletPayload>.stride
        descriptor.maxTotalThreadsPerObjectThreadgroup = Int(OBJECT_THREADS_PER_THREADGROUP)
        descriptor.maxTotalThreadsPerMeshThreadgroup = Int(MESH_THREADS_PER_THREADGROUP)
        descriptor.colorAttachments[0].pixelFormat = Self.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = Self.depthPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor, options: []).0
        hizCopyPipeline = try device.makeComputePipelineState(function: try function("hizCopyDepth"))
        hizDownsamplePipeline = try device.makeComputePipelineState(function: try function("hizDownsample"))

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw Error.meshShadersUnsupported
        }
        depthState = depth

        uniformBuffers = (0..<Self.maxFramesInFlight).map { i in
            let b = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!
            b.label = "uniforms[\(i)]"
            return b
        }
        statsBuffers = (0..<Self.maxFramesInFlight).map { i in
            let b = device.makeBuffer(length: MemoryLayout<UInt32>.stride * Int(STAT_COUNT), options: .storageModeShared)!
            b.label = "stats[\(i)]"
            return b
        }
        // 첫 프레임에는 모두 보였다고 가정 → 1패스가 전부 그리고 2패스가 비트를 정리한다
        let ones = [UInt32](repeating: 1, count: gpuMesh.meshletCount)
        visibilityBuffer = ones.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)!
        }
        visibilityBuffer.label = "visibility"

        stats.meshletCount = gpuMesh.meshletCount
        stats.triangleCount = gpuMesh.triangleCount
        stats.vertexCount = gpuMesh.vertexCount
        stats.materialCount = gpuMesh.materialCount
        stats.textureCount = gpuMesh.textureCount
        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.height > 0 else { return }
        camera.aspect = Float(size.width / size.height)
    }

    func draw(in view: MTKView) {
        guard let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        renderFrame(passDescriptor: passDescriptor, drawable: drawable, waitUntilCompleted: false)
    }

    // MARK: - 렌더링

    /// 한 프레임을 인코딩·커밋한다. `waitUntilCompleted`가 true면 완료까지 기다리고 그린 메시렛 수를 돌려준다.
    ///
    /// 오클루전이 켜져 있고 깊이 텍스처를 읽을 수 있으면 2패스로 그린다:
    /// 1패스(지난 프레임 가시 메시렛) → Hi-Z 피라미드 생성 → 2패스(나머지를 Hi-Z로 테스트, 가시성 비트 갱신).
    @discardableResult
    func renderFrame(passDescriptor: MTLRenderPassDescriptor, drawable: MTLDrawable?, waitUntilCompleted: Bool) -> Int? {
        inflight.wait()
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex += 1

        let depthTexture = passDescriptor.depthAttachment.texture
        let canOcclude = settings.occlusionEnabled
            && depthTexture.map { $0.usage.contains(.shaderRead) && $0.storageMode != .memoryless } == true
        if canOcclude, let depthTexture { ensureHiZ(width: depthTexture.width, height: depthTexture.height) }

        writeUniforms(into: uniformBuffers[slot], occlusion: canOcclude)
        let statsPointer = statsBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: Int(STAT_COUNT))
        for i in 0..<Int(STAT_COUNT) { statsPointer[i] = 0 }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflight.signal()
            return nil
        }
        commandBuffer.label = "Frame \(frameIndex)"

        if canOcclude, let hizTexture {
            // 1패스: 깊이를 저장해야 Hi-Z를 만들 수 있다
            let first = passDescriptor.copy() as! MTLRenderPassDescriptor
            first.depthAttachment.storeAction = .store
            encodeMeshPass(commandBuffer, descriptor: first, slot: slot, cullPass: UInt32(CULL_PASS_FIRST), label: "Pass 1 (prev visible)")
            encodeHiZBuild(commandBuffer, depth: depthTexture!, hiz: hizTexture)
            // 2패스: 이전 결과 위에 이어 그린다
            let second = passDescriptor.copy() as! MTLRenderPassDescriptor
            second.colorAttachments[0].loadAction = .load
            second.depthAttachment.loadAction = .load
            second.depthAttachment.storeAction = passDescriptor.depthAttachment.storeAction
            encodeMeshPass(commandBuffer, descriptor: second, slot: slot, cullPass: UInt32(CULL_PASS_SECOND), label: "Pass 2 (Hi-Z tested)")
        } else {
            encodeMeshPass(commandBuffer, descriptor: passDescriptor, slot: slot, cullPass: UInt32(CULL_PASS_SINGLE), label: "Meshlets")
        }

        if let drawable { commandBuffer.present(drawable) }

        let semaphore = inflight
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let drawn = Int(statsPointer[Int(STAT_DRAWN)])
            let occluded = Int(statsPointer[Int(STAT_OCCLUDED)])
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            semaphore.signal()
            guard !waitUntilCompleted else { return }
            DispatchQueue.main.async {
                self?.publishStats(visible: drawn, occluded: occluded, gpuTime: gpuTime)
            }
        }
        commandBuffer.commit()

        guard waitUntilCompleted else { return nil }
        commandBuffer.waitUntilCompleted()
        let drawn = Int(statsPointer[Int(STAT_DRAWN)])
        publishStats(visible: drawn, occluded: Int(statsPointer[Int(STAT_OCCLUDED)]),
                     gpuTime: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, force: true)
        return drawn
    }

    /// 지난 프레임 가시성 비트를 모두 1로 되돌린다 (카메라 급변 시 한 프레임 팝 방지용, 테스트용)
    func resetVisibility() {
        let p = visibilityBuffer.contents().bindMemory(to: UInt32.self, capacity: gpuMesh.meshletCount)
        for i in 0..<gpuMesh.meshletCount { p[i] = 1 }
    }

    private func encodeMeshPass(_ commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, slot: Int, cullPass: UInt32, label: String) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = label
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)   // 와인딩이 뒤집힌 파일도 보이게. 뒷면 제거는 object 스테이지의 콘 컬링이 담당
        encoder.setTriangleFillMode(settings.wireframe ? .lines : .fill)

        var pass = cullPass
        encoder.setObjectBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setObjectBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setObjectBuffer(statsBuffers[slot], offset: 0, index: Int(BUFFER_STATS))
        encoder.setObjectBytes(&pass, length: MemoryLayout<UInt32>.stride, index: Int(BUFFER_CULL_PASS))
        encoder.setObjectBuffer(visibilityBuffer, offset: 0, index: Int(BUFFER_VISIBILITY))
        if let hizTexture { encoder.setObjectTexture(hizTexture, index: Int(TEXTURE_HIZ)) }

        encoder.setMeshBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setMeshBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setMeshBuffer(gpuMesh.vertices, offset: 0, index: Int(BUFFER_VERTICES))
        encoder.setMeshBuffer(gpuMesh.meshletVertices, offset: 0, index: Int(BUFFER_MESHLET_VERTICES))
        encoder.setMeshBuffer(gpuMesh.meshletTriangles, offset: 0, index: Int(BUFFER_MESHLET_TRIANGLES))

        encoder.setFragmentBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setFragmentBuffer(gpuMesh.materials, offset: 0, index: Int(BUFFER_MATERIALS))
        encoder.useResources(gpuMesh.textures, usage: .read, stages: .fragment)
        if let environment {
            encoder.setFragmentTexture(environment.irradiance, index: Int(TEXTURE_IBL_IRRADIANCE))
            encoder.setFragmentTexture(environment.specular, index: Int(TEXTURE_IBL_SPECULAR))
            encoder.setFragmentTexture(environment.brdfLUT, index: Int(TEXTURE_IBL_BRDF_LUT))
        }

        let objectThreads = Int(OBJECT_THREADS_PER_THREADGROUP)
        let threadgroups = (gpuMesh.meshletCount + objectThreads - 1) / objectThreads
        encoder.drawMeshThreadgroups(
            MTLSize(width: threadgroups, height: 1, depth: 1),
            threadsPerObjectThreadgroup: MTLSize(width: objectThreads, height: 1, depth: 1),
            threadsPerMeshThreadgroup: MTLSize(width: Int(MESH_THREADS_PER_THREADGROUP), height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    // MARK: - Hi-Z

    private func ensureHiZ(width: Int, height: Int) {
        if let t = hizTexture, t.width == width, t.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: true)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else { return }
        texture.label = "HiZ"
        hizTexture = texture
        hizLevelViews = (0..<texture.mipmapLevelCount).compactMap {
            texture.makeTextureView(pixelFormat: .r32Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)
        }
    }

    private func encodeHiZBuild(_ commandBuffer: MTLCommandBuffer, depth: MTLTexture, hiz: MTLTexture) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder(), !hizLevelViews.isEmpty else { return }
        encoder.label = "HiZ build"
        func dispatch(_ pipeline: MTLComputePipelineState, width: Int, height: Int) {
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let grid = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        }
        encoder.setComputePipelineState(hizCopyPipeline)
        encoder.setTexture(depth, index: 0)
        encoder.setTexture(hizLevelViews[0], index: 1)
        dispatch(hizCopyPipeline, width: hiz.width, height: hiz.height)

        encoder.setComputePipelineState(hizDownsamplePipeline)
        for level in 1..<hizLevelViews.count {
            let dst = hizLevelViews[level]
            encoder.setTexture(hizLevelViews[level - 1], index: 0)
            encoder.setTexture(dst, index: 1)
            dispatch(hizDownsamplePipeline, width: dst.width, height: dst.height)
        }
        encoder.endEncoding()
    }

    private func publishStats(visible: Int, occluded: Int, gpuTime: Double, force: Bool = false) {
        stats.visibleMeshletCount = visible
        stats.occludedMeshletCount = occluded
        stats.gpuTime = gpuTime
        let now = Date()
        if force || now.timeIntervalSince(lastStatsReport) > 0.25 {
            lastStatsReport = now
            onStats?(stats)
        }
    }

    private func writeUniforms(into buffer: MTLBuffer, occlusion: Bool) {
        let view = camera.viewMatrix
        let projection = camera.projectionMatrix
        let viewProjection = projection * view

        var u = Uniforms()
        u.modelViewProjection = viewProjection
        u.modelView = view
        u.normalMatrix = Math.upperLeft3x3(view)   // 모델 행렬이 단위행렬 + 순수 회전이라 역전치 불필요
        u.cameraPositionModel = camera.position
        u.meshletCount = UInt32(gpuMesh.meshletCount)
        u.debugMode = settings.debugMode.rawValue
        u.cullingEnabled = settings.cullingEnabled ? 1 : 0
        u.texturesEnabled = settings.texturesEnabled ? 1 : 0
        u.occlusionEnabled = occlusion ? 1 : 0
        u.viewToWorld = simd_transpose(Math.upperLeft3x3(view))   // 순수 회전 → 역행렬 = 전치
        u.exposure = settings.exposure
        u.iblEnabled = (environment != nil && settings.iblEnabled) ? 1 : 0
        u.envSpecularMipCount = Float(environment?.specularMipCount ?? 1)
        if let hizTexture {
            u.hizSize = SIMD2(UInt32(hizTexture.width), UInt32(hizTexture.height))
            u.hizMipCount = UInt32(hizTexture.mipmapLevelCount)
        }

        let planes = Math.frustumPlanes(from: viewProjection)
        withUnsafeMutablePointer(to: &u.frustumPlanes) { tuple in
            tuple.withMemoryRebound(to: simd_float4.self, capacity: 6) { p in
                for i in 0..<6 { p[i] = planes[i] }
            }
        }
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<Uniforms>.stride)
    }
}
