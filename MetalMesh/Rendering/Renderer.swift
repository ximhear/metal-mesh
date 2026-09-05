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
    private let gpuMesh: GPUMesh
    private let uniformBuffers: [MTLBuffer]
    private let statsBuffers: [MTLBuffer]
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
            let b = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)!
            b.label = "stats[\(i)]"
            return b
        }

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

    /// 한 프레임을 인코딩·커밋한다. `waitUntilCompleted`가 true면 완료까지 기다리고 보이는 메시렛 수를 돌려준다.
    @discardableResult
    func renderFrame(passDescriptor: MTLRenderPassDescriptor, drawable: MTLDrawable?, waitUntilCompleted: Bool) -> Int? {
        inflight.wait()
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex += 1

        writeUniforms(into: uniformBuffers[slot])
        let statsPointer = statsBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: 1)
        statsPointer.pointee = 0

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            inflight.signal()
            return nil
        }
        commandBuffer.label = "Frame \(frameIndex)"
        encoder.label = "Meshlets"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)   // 와인딩이 뒤집힌 파일도 보이게. 뒷면 제거는 object 스테이지의 콘 컬링이 담당
        encoder.setTriangleFillMode(settings.wireframe ? .lines : .fill)

        encoder.setObjectBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setObjectBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setObjectBuffer(statsBuffers[slot], offset: 0, index: Int(BUFFER_STATS))

        encoder.setMeshBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setMeshBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setMeshBuffer(gpuMesh.vertices, offset: 0, index: Int(BUFFER_VERTICES))
        encoder.setMeshBuffer(gpuMesh.meshletVertices, offset: 0, index: Int(BUFFER_MESHLET_VERTICES))
        encoder.setMeshBuffer(gpuMesh.meshletTriangles, offset: 0, index: Int(BUFFER_MESHLET_TRIANGLES))

        encoder.setFragmentBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setFragmentBuffer(gpuMesh.materials, offset: 0, index: Int(BUFFER_MATERIALS))
        // 인자 버퍼로 간접 참조되는 텍스처는 명시적으로 상주시켜야 한다
        encoder.useResources(gpuMesh.textures, usage: .read, stages: .fragment)

        let objectThreads = Int(OBJECT_THREADS_PER_THREADGROUP)
        let threadgroups = (gpuMesh.meshletCount + objectThreads - 1) / objectThreads
        encoder.drawMeshThreadgroups(
            MTLSize(width: threadgroups, height: 1, depth: 1),
            threadsPerObjectThreadgroup: MTLSize(width: objectThreads, height: 1, depth: 1),
            threadsPerMeshThreadgroup: MTLSize(width: Int(MESH_THREADS_PER_THREADGROUP), height: 1, depth: 1)
        )
        encoder.endEncoding()

        if let drawable { commandBuffer.present(drawable) }

        let semaphore = inflight
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let visible = Int(statsPointer.pointee)
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            semaphore.signal()
            guard !waitUntilCompleted else { return }
            DispatchQueue.main.async {
                self?.publishStats(visible: visible, gpuTime: gpuTime)
            }
        }
        commandBuffer.commit()

        guard waitUntilCompleted else { return nil }
        commandBuffer.waitUntilCompleted()
        let visible = Int(statsPointer.pointee)
        publishStats(visible: visible, gpuTime: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, force: true)
        return visible
    }

    private func publishStats(visible: Int, gpuTime: Double, force: Bool = false) {
        stats.visibleMeshletCount = visible
        stats.gpuTime = gpuTime
        let now = Date()
        if force || now.timeIntervalSince(lastStatsReport) > 0.25 {
            lastStatsReport = now
            onStats?(stats)
        }
    }

    private func writeUniforms(into buffer: MTLBuffer) {
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

        let planes = Math.frustumPlanes(from: viewProjection)
        withUnsafeMutablePointer(to: &u.frustumPlanes) { tuple in
            tuple.withMemoryRebound(to: simd_float4.self, capacity: 6) { p in
                for i in 0..<6 { p[i] = planes[i] }
            }
        }
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<Uniforms>.stride)
    }
}
