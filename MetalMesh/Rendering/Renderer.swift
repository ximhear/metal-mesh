import Foundation
import Metal
import MetalFX
import MetalKit
import MeshCore
import simd

/// 메시 셰이더 파이프라인으로 메시렛 메시 하나를 그린다. 뷰어 인스턴스는 메인 스레드에서 사용한다.
/// 썸네일용 인스턴스는 별도 작업에서 만들고 그 작업 안에서만 사용한다.
///
/// 프레임 구조:
///   [내부 타깃, 렌더 해상도] 1패스(지난 프레임 가시) → Hi-Z → 2패스(오클루전 테스트)
///   → (renderScale < 1이면) MetalFX 공간 업스케일 → 프레젠트 패스로 드로어블/대상 텍스처에 복사
/// MSAA는 내부 컬러·깊이에 적용하고 깊이는 max 필터로 리졸브해 Hi-Z에 쓴다.
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
    /// 드로어블/스냅샷 대상 포맷
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    /// 내부 렌더 타깃 포맷 (톤매핑 후 선형 0…1, MetalFX 입력)
    static let internalColorFormat: MTLPixelFormat = .rgba16Float
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    static let clearColor = MTLClearColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)

    let device: MTLDevice
    let camera = OrbitCamera()
    var settings = RenderSettings()
    /// 통계가 갱신될 때 메인 스레드에서 호출된다 (약 4회/초)
    var onStats: ((RenderStats) -> Void)?
    /// IBL 환경 (없으면 방향광 폴백)
    let environment: IBLEnvironment?
    static var supportsMetalFX: Bool { MTLFXSpatialScalerDescriptor.supportsDevice(MTLCreateSystemDefaultDevice()!) }

    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var meshPipelines: [Int: MTLRenderPipelineState] = [:]     // sampleCount → 파이프라인
    private var groundPipelines: [Int: MTLRenderPipelineState] = [:]
    private var presentPipelines: [UInt: MTLRenderPipelineState] = [:] // 대상 포맷 → 파이프라인
    private var shadowPipeline: MTLRenderPipelineState?
    private let ssaoPipeline: MTLComputePipelineState
    private let ssaoBlurPipeline: MTLComputePipelineState
    private let shadowMap: MTLTexture
    private let shadowUniformBuffers: [MTLBuffer]
    private let shadowStatsBuffer: MTLBuffer
    private let ssaoUniformBuffers: [MTLBuffer]
    /// 모델 경계 (그림자 프러스텀·바닥 배치)
    private let sceneCenter: SIMD3<Float>
    private let sceneRadius: Float
    private let sceneMinY: Float

    var groundPosition: SIMD3<Float> {
        SIMD3(sceneCenter.x, sceneMinY - sceneRadius * 0.002, sceneCenter.z)
    }
    /// 표면 → 태양 방향 (모델 공간, 정규화)
    let sunDirection = simd_normalize(SIMD3<Float>(0.45, 1.0, 0.35))
    static let shadowMapSize = 2048
    private let depthState: MTLDepthStencilState
    private let hizCopyPipeline: MTLComputePipelineState
    private let hizDownsamplePipeline: MTLComputePipelineState
    private let gpuMesh: GPUMesh
    private let uniformBuffers: [MTLBuffer]
    private let statsBuffers: [MTLBuffer]
    private let visibilityBuffer: MTLBuffer
    private let lodBuffer: MTLBuffer
    private let lodLevelCount: Int
    private let inflight = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    private var frameIndex = 0
    private var lastStatsReport = Date.distantPast

    /// 내부 렌더 타깃 묶음. 출력 크기·renderScale·MSAA가 바뀌면 다시 만든다.
    private struct Targets {
        var renderWidth: Int, renderHeight: Int
        var outputWidth: Int, outputHeight: Int
        var samples: Int
        var color: MTLTexture           // 단일 샘플 (MSAA면 리졸브 대상)
        var colorMS: MTLTexture?
        var depth: MTLTexture           // 단일 샘플, shaderRead (Hi-Z 입력)
        var depthMS: MTLTexture?
        var upscaled: MTLTexture?       // MetalFX 출력 (출력 해상도)
        var scaler: MTLFXSpatialScaler?
        var hiz: MTLTexture
        var hizLevels: [MTLTexture]
        var aoRaw: MTLTexture
        var ao: MTLTexture
    }
    private var targets: Targets?

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
        self.library = library
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw Error.functionNotFound(name) }
            return f
        }
        hizCopyPipeline = try device.makeComputePipelineState(function: try function("hizCopyDepth"))
        hizDownsamplePipeline = try device.makeComputePipelineState(function: try function("hizDownsample"))
        ssaoPipeline = try device.makeComputePipelineState(function: try function("ssaoMain"))
        ssaoBlurPipeline = try device.makeComputePipelineState(function: try function("ssaoBlur"))

        let shadowDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthPixelFormat, width: Self.shadowMapSize, height: Self.shadowMapSize, mipmapped: false)
        shadowDesc.usage = [.renderTarget, .shaderRead]
        shadowDesc.storageMode = .private
        guard let shadowMap = device.makeTexture(descriptor: shadowDesc) else { throw Error.meshShadersUnsupported }
        shadowMap.label = "shadowMap"
        self.shadowMap = shadowMap
        shadowUniformBuffers = (0..<Self.maxFramesInFlight).map { i in
            let b = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!
            b.label = "shadowUniforms[\(i)]"
            return b
        }
        ssaoUniformBuffers = (0..<Self.maxFramesInFlight).map { i in
            let b = device.makeBuffer(length: MemoryLayout<SSAOUniforms>.stride, options: .storageModeShared)!
            b.label = "ssaoUniforms[\(i)]"
            return b
        }
        shadowStatsBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * Int(STAT_COUNT), options: .storageModeShared)!

        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude), maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices { minP = simd_min(minP, v.position); maxP = simd_max(maxP, v.position) }
        sceneCenter = (minP + maxP) * 0.5
        sceneRadius = max(simd_length(maxP - minP) * 0.5, 1e-4)
        sceneMinY = minP.y

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw Error.meshShadersUnsupported }
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
        let ones = [UInt32](repeating: 1, count: gpuMesh.meshletCount)
        visibilityBuffer = ones.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)!
        }
        visibilityBuffer.label = "visibility"
        var lods = mesh.lod
        if lods.count != mesh.meshlets.count {
            lods = mesh.meshlets.map { m in
                var l = MeshletLOD(); l.center = m.boundsCenter; l.radius = m.boundsRadius; l.parentError = LOD_ERROR_INFINITE; return l
            }
        }
        lodBuffer = lods.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)!
        }
        lodBuffer.label = "meshletLOD"
        lodLevelCount = mesh.lodLevelCount

        stats.meshletCount = gpuMesh.meshletCount
        stats.triangleCount = mesh.level0TriangleCount
        stats.lodLevelCount = mesh.lodLevelCount
        stats.vertexCount = gpuMesh.vertexCount
        stats.materialCount = gpuMesh.materialCount
        stats.textureCount = gpuMesh.textureCount
        super.init()
        _ = try meshPipeline(sampleCount: 1)
    }

    // MARK: - 파이프라인

    private func meshPipeline(sampleCount: Int) throws -> MTLRenderPipelineState {
        if let p = meshPipelines[sampleCount] { return p }
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw Error.functionNotFound(name) }
            return f
        }
        let descriptor = MTLMeshRenderPipelineDescriptor()
        descriptor.label = "MeshletPipeline x\(sampleCount)"
        descriptor.objectFunction = try function("objectMain")
        descriptor.meshFunction = try function("meshMain")
        descriptor.fragmentFunction = try function("fragmentMain")
        descriptor.payloadMemoryLength = MemoryLayout<MeshletPayload>.stride
        descriptor.maxTotalThreadsPerObjectThreadgroup = Int(OBJECT_THREADS_PER_THREADGROUP)
        descriptor.maxTotalThreadsPerMeshThreadgroup = Int(MESH_THREADS_PER_THREADGROUP)
        descriptor.colorAttachments[0].pixelFormat = Self.internalColorFormat
        descriptor.depthAttachmentPixelFormat = Self.depthPixelFormat
        descriptor.rasterSampleCount = sampleCount
        let p = try device.makeRenderPipelineState(descriptor: descriptor, options: []).0
        meshPipelines[sampleCount] = p
        return p
    }

    func makeShadowPipeline() throws -> MTLRenderPipelineState {
        if let p = shadowPipeline { return p }
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw Error.functionNotFound(name) }
            return f
        }
        let descriptor = MTLMeshRenderPipelineDescriptor()
        descriptor.label = "ShadowPipeline"
        descriptor.objectFunction = try function("objectMain")
        descriptor.meshFunction = try function("meshMain")
        descriptor.fragmentFunction = nil   // 깊이 전용
        descriptor.payloadMemoryLength = MemoryLayout<MeshletPayload>.stride
        descriptor.maxTotalThreadsPerObjectThreadgroup = Int(OBJECT_THREADS_PER_THREADGROUP)
        descriptor.maxTotalThreadsPerMeshThreadgroup = Int(MESH_THREADS_PER_THREADGROUP)
        descriptor.depthAttachmentPixelFormat = Self.depthPixelFormat
        let p = try device.makeRenderPipelineState(descriptor: descriptor, options: []).0
        shadowPipeline = p
        return p
    }

    private func groundPipeline(sampleCount: Int) throws -> MTLRenderPipelineState {
        if let p = groundPipelines[sampleCount] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.label = "Ground x\(sampleCount)"
        d.vertexFunction = library.makeFunction(name: "groundVertex")
        d.fragmentFunction = library.makeFunction(name: "groundFragment")
        d.colorAttachments[0].pixelFormat = Self.internalColorFormat
        d.depthAttachmentPixelFormat = Self.depthPixelFormat
        d.rasterSampleCount = sampleCount
        let p = try device.makeRenderPipelineState(descriptor: d)
        groundPipelines[sampleCount] = p
        return p
    }

    private func presentPipeline(format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = presentPipelines[format.rawValue] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.label = "Present"
        d.vertexFunction = library.makeFunction(name: "presentVertex")
        d.fragmentFunction = library.makeFunction(name: "presentFragment")
        d.colorAttachments[0].pixelFormat = format
        let p = try device.makeRenderPipelineState(descriptor: d)
        presentPipelines[format.rawValue] = p
        return p
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

    /// 한 프레임을 인코딩·커밋한다. `passDescriptor`의 컬러 텍스처가 최종 출력 대상이다.
    /// `waitUntilCompleted`가 true면 완료까지 기다리고 그린 메시렛 수를 돌려준다.
    @discardableResult
    func renderFrame(passDescriptor: MTLRenderPassDescriptor, drawable: MTLDrawable?, waitUntilCompleted: Bool) -> Int? {
        guard let destination = passDescriptor.colorAttachments[0].texture else { return nil }
        inflight.wait()
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex += 1

        guard let targets = ensureTargets(outputWidth: destination.width, outputHeight: destination.height),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflight.signal()
            return nil
        }
        commandBuffer.label = "Frame \(frameIndex)"

        let occlusion = settings.occlusionEnabled
        writeUniforms(into: uniformBuffers[slot], occlusion: occlusion, renderHeight: targets.renderHeight)
        let statsPointer = statsBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: Int(STAT_COUNT))
        for i in 0..<Int(STAT_COUNT) { statsPointer[i] = 0 }

        // 섀도 패스: 라이트 직교 투영으로 깊이만 (같은 LOD 컷, 오클루전 없음)
        if settings.shadowsEnabled, let shadowPipeline = try? makeShadowPipeline() {
            writeShadowUniforms(into: shadowUniformBuffers[slot], from: uniformBuffers[slot])
            let shadowPass = MTLRenderPassDescriptor()
            shadowPass.depthAttachment.texture = shadowMap
            shadowPass.depthAttachment.loadAction = .clear
            shadowPass.depthAttachment.storeAction = .store
            shadowPass.depthAttachment.clearDepth = 1
            encodeMeshPass(commandBuffer, descriptor: shadowPass, pipeline: shadowPipeline, uniforms: shadowUniformBuffers[slot],
                           stats: shadowStatsBuffer, cullPass: UInt32(CULL_PASS_SINGLE), hiz: targets.hiz, drawGround: false, sampleCount: 1, label: "Shadow map")
        }

        // 내부 타깃 패스 서술자
        let first = MTLRenderPassDescriptor()
        if let ms = targets.colorMS {
            first.colorAttachments[0].texture = ms
            first.colorAttachments[0].resolveTexture = targets.color
            // 2패스가 이어 그리려면 MS 내용을 남겨야 한다. 리졸브는 마지막 패스에서
            first.colorAttachments[0].storeAction = occlusion ? .store : .multisampleResolve
        } else {
            first.colorAttachments[0].texture = targets.color
            first.colorAttachments[0].storeAction = .store
        }
        first.colorAttachments[0].loadAction = .clear
        first.colorAttachments[0].clearColor = Self.clearColor
        if let dms = targets.depthMS {
            first.depthAttachment.texture = dms
            first.depthAttachment.resolveTexture = targets.depth
            first.depthAttachment.storeAction = .storeAndMultisampleResolve
            first.depthAttachment.depthResolveFilter = .max   // 가장 먼 샘플 → Hi-Z가 보수적
        } else {
            first.depthAttachment.texture = targets.depth
            first.depthAttachment.storeAction = .store
        }
        first.depthAttachment.loadAction = .clear
        first.depthAttachment.clearDepth = 1

        let pipeline: MTLRenderPipelineState
        do { pipeline = try meshPipeline(sampleCount: targets.samples) } catch { inflight.signal(); return nil }

        let mainUniforms = uniformBuffers[slot]
        if occlusion {
            encodeMeshPass(commandBuffer, descriptor: first, pipeline: pipeline, uniforms: mainUniforms, stats: statsBuffers[slot],
                           cullPass: UInt32(CULL_PASS_FIRST), hiz: targets.hiz, drawGround: settings.groundEnabled, sampleCount: targets.samples, label: "Pass 1 (prev visible)")
            encodeHiZBuild(commandBuffer, depth: targets.depth, levels: targets.hizLevels)
            let second = first.copy() as! MTLRenderPassDescriptor
            second.colorAttachments[0].loadAction = .load
            second.depthAttachment.loadAction = .load
            if targets.colorMS != nil { second.colorAttachments[0].storeAction = .multisampleResolve }
            if targets.depthMS != nil { second.depthAttachment.storeAction = .storeAndMultisampleResolve }
            encodeMeshPass(commandBuffer, descriptor: second, pipeline: pipeline, uniforms: mainUniforms, stats: statsBuffers[slot],
                           cullPass: UInt32(CULL_PASS_SECOND), hiz: targets.hiz, drawGround: false, sampleCount: targets.samples, label: "Pass 2 (Hi-Z tested)")
        } else {
            encodeMeshPass(commandBuffer, descriptor: first, pipeline: pipeline, uniforms: mainUniforms, stats: statsBuffers[slot],
                           cullPass: UInt32(CULL_PASS_SINGLE), hiz: targets.hiz, drawGround: settings.groundEnabled, sampleCount: targets.samples, label: "Meshlets")
        }

        // SSAO (리졸브된 깊이 기준, 렌더 해상도)
        if settings.ssaoEnabled {
            writeSSAOUniforms(into: ssaoUniformBuffers[slot], width: targets.renderWidth, height: targets.renderHeight)
            if let e = commandBuffer.makeComputeCommandEncoder() {
                e.label = "SSAO"
                let tg = MTLSize(width: 8, height: 8, depth: 1)
                let grid = MTLSize(width: (targets.renderWidth + 7) / 8, height: (targets.renderHeight + 7) / 8, depth: 1)
                e.setComputePipelineState(ssaoPipeline)
                e.setTexture(targets.depth, index: 0)
                e.setTexture(targets.aoRaw, index: 1)
                e.setBuffer(ssaoUniformBuffers[slot], offset: 0, index: 0)
                e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                e.setComputePipelineState(ssaoBlurPipeline)
                e.setTexture(targets.aoRaw, index: 0)
                e.setTexture(targets.ao, index: 1)
                e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                e.endEncoding()
            }
        }

        // 업스케일
        var presented = targets.color
        if let scaler = targets.scaler, let upscaled = targets.upscaled {
            scaler.colorTexture = targets.color
            scaler.outputTexture = upscaled
            scaler.encode(commandBuffer: commandBuffer)
            presented = upscaled
        }

        // 프레젠트: 대상 텍스처로 복사
        let present = MTLRenderPassDescriptor()
        present.colorAttachments[0].texture = destination
        present.colorAttachments[0].loadAction = .dontCare
        present.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: present),
           let presentPipeline = try? presentPipeline(format: destination.pixelFormat) {
            encoder.label = "Present"
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(presented, index: 0)
            encoder.setFragmentTexture(targets.ao, index: 1)
            var aoStrength: Float = settings.ssaoEnabled ? 1.0 : 0.0
            encoder.setFragmentBytes(&aoStrength, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        if let drawable { commandBuffer.present(drawable) }

        let semaphore = inflight
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let drawn = Int(statsPointer[Int(STAT_DRAWN)])
            let occluded = Int(statsPointer[Int(STAT_OCCLUDED)])
            let triangles = Int(statsPointer[Int(STAT_TRIANGLES)])
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            semaphore.signal()
            guard !waitUntilCompleted else { return }
            DispatchQueue.main.async {
                self?.publishStats(visible: drawn, occluded: occluded, triangles: triangles, gpuTime: gpuTime)
            }
        }
        commandBuffer.commit()

        guard waitUntilCompleted else { return nil }
        commandBuffer.waitUntilCompleted()
        let drawn = Int(statsPointer[Int(STAT_DRAWN)])
        publishStats(visible: drawn, occluded: Int(statsPointer[Int(STAT_OCCLUDED)]), triangles: Int(statsPointer[Int(STAT_TRIANGLES)]),
                     gpuTime: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, force: true)
        return drawn
    }

    /// 지난 프레임 가시성 비트를 모두 1로 되돌린다 (테스트/카메라 급변용)
    func resetVisibility() {
        let p = visibilityBuffer.contents().bindMemory(to: UInt32.self, capacity: gpuMesh.meshletCount)
        for i in 0..<gpuMesh.meshletCount { p[i] = 1 }
    }

    private func encodeMeshPass(_ commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, pipeline: MTLRenderPipelineState,
                                uniforms: MTLBuffer, stats: MTLBuffer, cullPass: UInt32, hiz: MTLTexture, drawGround: Bool, sampleCount: Int, label: String) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = label
        let isShadow = descriptor.colorAttachments[0].texture == nil

        // 바닥 (메시렛 앞에 그려 Hi-Z에도 포함)
        if drawGround, !isShadow, let ground = try? groundPipeline(sampleCount: sampleCount) {
            encoder.setRenderPipelineState(ground)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(uniforms, offset: 0, index: Int(BUFFER_UNIFORMS))
            encoder.setFragmentBuffer(uniforms, offset: 0, index: Int(BUFFER_UNIFORMS))
            if let environment { encoder.setFragmentTexture(environment.irradiance, index: Int(TEXTURE_IBL_IRRADIANCE)) }
            encoder.setFragmentTexture(shadowMap, index: Int(TEXTURE_SHADOW_MAP))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(settings.wireframe && !isShadow ? .lines : .fill)
        if isShadow {
            // 섀도 아크네 완화: 라이트 방향 깊이 바이어스
            encoder.setDepthBias(1.0, slopeScale: 2.0, clamp: 0.01)
        }

        var pass = cullPass
        encoder.setObjectBuffer(uniforms, offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setObjectBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setObjectBuffer(stats, offset: 0, index: Int(BUFFER_STATS))
        encoder.setObjectBytes(&pass, length: MemoryLayout<UInt32>.stride, index: Int(BUFFER_CULL_PASS))
        encoder.setObjectBuffer(visibilityBuffer, offset: 0, index: Int(BUFFER_VISIBILITY))
        encoder.setObjectBuffer(lodBuffer, offset: 0, index: Int(BUFFER_MESHLET_LOD))
        encoder.setObjectTexture(hiz, index: Int(TEXTURE_HIZ))

        encoder.setMeshBuffer(uniforms, offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setMeshBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setMeshBuffer(gpuMesh.vertices, offset: 0, index: Int(BUFFER_VERTICES))
        encoder.setMeshBuffer(gpuMesh.meshletVertices, offset: 0, index: Int(BUFFER_MESHLET_VERTICES))
        encoder.setMeshBuffer(gpuMesh.meshletTriangles, offset: 0, index: Int(BUFFER_MESHLET_TRIANGLES))

        if !isShadow {
            encoder.setFragmentBuffer(uniforms, offset: 0, index: Int(BUFFER_UNIFORMS))
            encoder.setFragmentBuffer(gpuMesh.materials, offset: 0, index: Int(BUFFER_MATERIALS))
            encoder.useResources(gpuMesh.textures, usage: .read, stages: .fragment)
            if let environment {
                encoder.setFragmentTexture(environment.irradiance, index: Int(TEXTURE_IBL_IRRADIANCE))
                encoder.setFragmentTexture(environment.specular, index: Int(TEXTURE_IBL_SPECULAR))
                encoder.setFragmentTexture(environment.brdfLUT, index: Int(TEXTURE_IBL_BRDF_LUT))
            }
            encoder.setFragmentTexture(shadowMap, index: Int(TEXTURE_SHADOW_MAP))
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

    // MARK: - 타깃

    private func ensureTargets(outputWidth: Int, outputHeight: Int) -> Targets? {
        let scale = max(min(settings.renderScale, 1), 0.25)
        let renderWidth = max(Int((Float(outputWidth) * scale).rounded()), 1)
        let renderHeight = max(Int((Float(outputHeight) * scale).rounded()), 1)
        let samples = settings.msaaSamples == 4 && device.supportsTextureSampleCount(4) ? 4 : 1
        if let t = targets, t.renderWidth == renderWidth, t.renderHeight == renderHeight,
           t.outputWidth == outputWidth, t.outputHeight == outputHeight, t.samples == samples {
            return t
        }

        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage, samples: Int = 1, label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            if samples > 1 { d.textureType = .type2DMultisample; d.sampleCount = samples }
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        guard let color = texture(Self.internalColorFormat, renderWidth, renderHeight, usage: [.renderTarget, .shaderRead], label: "color"),
              let depth = texture(Self.depthPixelFormat, renderWidth, renderHeight, usage: [.renderTarget, .shaderRead], label: "depth") else { return nil }
        var colorMS: MTLTexture?
        var depthMS: MTLTexture?
        if samples > 1 {
            colorMS = texture(Self.internalColorFormat, renderWidth, renderHeight, usage: .renderTarget, samples: samples, label: "colorMS")
            depthMS = texture(Self.depthPixelFormat, renderWidth, renderHeight, usage: .renderTarget, samples: samples, label: "depthMS")
        }

        // Hi-Z
        let hizDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: renderWidth, height: renderHeight, mipmapped: true)
        hizDesc.usage = [.shaderRead, .shaderWrite]
        hizDesc.storageMode = .private
        guard let hiz = device.makeTexture(descriptor: hizDesc) else { return nil }
        hiz.label = "HiZ"
        let hizLevels = (0..<hiz.mipmapLevelCount).compactMap {
            hiz.makeTextureView(pixelFormat: .r32Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)
        }

        // MetalFX 공간 업스케일러
        var scaler: MTLFXSpatialScaler?
        var upscaled: MTLTexture?
        if renderWidth != outputWidth || renderHeight != outputHeight, MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            let sd = MTLFXSpatialScalerDescriptor()
            sd.inputWidth = renderWidth; sd.inputHeight = renderHeight
            sd.outputWidth = outputWidth; sd.outputHeight = outputHeight
            sd.colorTextureFormat = Self.internalColorFormat
            sd.outputTextureFormat = Self.internalColorFormat
            sd.colorProcessingMode = .linear
            scaler = sd.makeSpatialScaler(device: device)
            upscaled = texture(Self.internalColorFormat, outputWidth, outputHeight, usage: [.renderTarget, .shaderRead, .shaderWrite], label: "upscaled")
            if scaler == nil || upscaled == nil { scaler = nil; upscaled = nil }
        }

        guard let aoRaw = texture(.r8Unorm, renderWidth, renderHeight, usage: [.shaderRead, .shaderWrite], label: "aoRaw"),
              let ao = texture(.r8Unorm, renderWidth, renderHeight, usage: [.shaderRead, .shaderWrite], label: "ao") else { return nil }
        let t = Targets(renderWidth: renderWidth, renderHeight: renderHeight, outputWidth: outputWidth, outputHeight: outputHeight,
                        samples: samples, color: color, colorMS: colorMS, depth: depth, depthMS: depthMS,
                        upscaled: upscaled, scaler: scaler, hiz: hiz, hizLevels: hizLevels, aoRaw: aoRaw, ao: ao)
        targets = t
        stats.renderWidth = renderWidth; stats.renderHeight = renderHeight
        stats.outputWidth = outputWidth; stats.outputHeight = outputHeight
        stats.upscalerActive = scaler != nil
        return t
    }

    // MARK: - Hi-Z

    private func encodeHiZBuild(_ commandBuffer: MTLCommandBuffer, depth: MTLTexture, levels: [MTLTexture]) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder(), !levels.isEmpty else { return }
        encoder.label = "HiZ build"
        func dispatch(width: Int, height: Int) {
            encoder.dispatchThreadgroups(MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        encoder.setComputePipelineState(hizCopyPipeline)
        encoder.setTexture(depth, index: 0)
        encoder.setTexture(levels[0], index: 1)
        dispatch(width: levels[0].width, height: levels[0].height)
        encoder.setComputePipelineState(hizDownsamplePipeline)
        for level in 1..<levels.count {
            encoder.setTexture(levels[level - 1], index: 0)
            encoder.setTexture(levels[level], index: 1)
            dispatch(width: levels[level].width, height: levels[level].height)
        }
        encoder.endEncoding()
    }

    // MARK: - 유니폼/통계

    private func publishStats(visible: Int, occluded: Int, triangles: Int, gpuTime: Double, force: Bool = false) {
        stats.visibleMeshletCount = visible
        stats.occludedMeshletCount = occluded
        stats.drawnTriangleCount = triangles
        stats.gpuTime = gpuTime
        let now = Date()
        if force || now.timeIntervalSince(lastStatsReport) > 0.25 {
            lastStatsReport = now
            onStats?(stats)
        }
    }

    /// 메인 유니폼을 복사해 라이트 시점으로 바꾼다 (LOD 컷은 메인 카메라 기준 유지)
    private func writeShadowUniforms(into buffer: MTLBuffer, from main: MTLBuffer) {
        var u = main.contents().load(as: Uniforms.self)
        u.modelViewProjection = u.lightViewProjection
        u.cameraPositionModel = sceneCenter + sunDirection * (sceneRadius * 3)   // 콘 컬링: 라이트 기준 뒷면
        u.occlusionEnabled = 0
        let planes = Math.frustumPlanes(from: u.lightViewProjection)
        withUnsafeMutablePointer(to: &u.frustumPlanes) { tuple in
            tuple.withMemoryRebound(to: simd_float4.self, capacity: 6) { p in for i in 0..<6 { p[i] = planes[i] } }
        }
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<Uniforms>.stride)
    }

    private func writeSSAOUniforms(into buffer: MTLBuffer, width: Int, height: Int) {
        var u = SSAOUniforms()
        u.projection = camera.projectionMatrix
        u.inverseProjection = simd_inverse(camera.projectionMatrix)
        u.screenSize = SIMD2(Float(width), Float(height))
        u.radius = sceneRadius * 0.06
        u.bias = sceneRadius * 0.0015
        u.intensity = 1.1
        u.frameIndex = UInt32(frameIndex)
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<SSAOUniforms>.stride)
    }

    private func writeUniforms(into buffer: MTLBuffer, occlusion: Bool, renderHeight: Int) {
        let view = camera.viewMatrix
        let projection = camera.projectionMatrix
        let viewProjection = projection * view

        var u = Uniforms()
        u.modelViewProjection = viewProjection
        u.modelView = view
        u.normalMatrix = Math.upperLeft3x3(view)
        u.cameraPositionModel = camera.position
        u.meshletCount = UInt32(gpuMesh.meshletCount)
        u.debugMode = settings.debugMode.rawValue
        u.cullingEnabled = settings.cullingEnabled ? 1 : 0
        u.texturesEnabled = settings.texturesEnabled ? 1 : 0
        u.occlusionEnabled = occlusion ? 1 : 0
        u.viewToWorld = simd_transpose(Math.upperLeft3x3(view))
        u.exposure = settings.exposure
        u.iblEnabled = (environment != nil && settings.iblEnabled) ? 1 : 0
        u.envSpecularMipCount = Float(environment?.specularMipCount ?? 1)
        u.lodEnabled = (settings.lodEnabled && lodLevelCount > 1) ? 1 : 0
        u.lodThresholdPx = max(settings.lodThresholdPx, 0.05)
        u.lodScale = Float(renderHeight) / (2 * tan(camera.fovY * 0.5))
        if let t = targets {
            u.hizSize = SIMD2(UInt32(t.hiz.width), UInt32(t.hiz.height))
            u.hizMipCount = UInt32(t.hiz.mipmapLevelCount)
        }
        u.lodCameraPositionModel = camera.position
        // 태양: 모델 경계 구를 덮는 직교 프러스텀
        let lightEye = sceneCenter + sunDirection * (sceneRadius * 3)
        let up: SIMD3<Float> = abs(sunDirection.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let lightView = Math.lookAt(eye: lightEye, target: sceneCenter, up: up)
        let lightProjection = Math.orthographic(left: -sceneRadius, right: sceneRadius, bottom: -sceneRadius, top: sceneRadius,
                                                near: sceneRadius * 1.5, far: sceneRadius * 4.5)
        u.lightViewProjection = lightProjection * lightView
        u.lightDirectionView = simd_normalize(Math.upperLeft3x3(view) * sunDirection)
        u.sunIntensity = settings.iblEnabled && environment != nil ? 1.6 : 0
        u.shadowsEnabled = settings.shadowsEnabled ? 1 : 0
        u.shadowBias = 0.0015
        u.groundY = groundPosition.y
        u.groundCenter = SIMD2(groundPosition.x, groundPosition.z)
        u.groundRadius = sceneRadius * 8
        u.groundEnabled = settings.groundEnabled ? 1 : 0
        let planes = Math.frustumPlanes(from: viewProjection)
        withUnsafeMutablePointer(to: &u.frustumPlanes) { tuple in
            tuple.withMemoryRebound(to: simd_float4.self, capacity: 6) { p in
                for i in 0..<6 { p[i] = planes[i] }
            }
        }
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<Uniforms>.stride)
    }
}
