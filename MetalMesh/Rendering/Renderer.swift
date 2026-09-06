import Foundation
import Metal
import MetalFX
import MetalKit
import MeshCore
import simd

/// 메시 셰이더 파이프라인으로 메시렛 메시 하나를 그린다. 모든 메서드는 메인 스레드에서 호출한다.
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
    private var presentPipelines: [UInt: MTLRenderPipelineState] = [:] // 대상 포맷 → 파이프라인
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

        if occlusion {
            encodeMeshPass(commandBuffer, descriptor: first, pipeline: pipeline, slot: slot, cullPass: UInt32(CULL_PASS_FIRST), hiz: targets.hiz, label: "Pass 1 (prev visible)")
            encodeHiZBuild(commandBuffer, depth: targets.depth, levels: targets.hizLevels)
            let second = first.copy() as! MTLRenderPassDescriptor
            second.colorAttachments[0].loadAction = .load
            second.depthAttachment.loadAction = .load
            if targets.colorMS != nil { second.colorAttachments[0].storeAction = .multisampleResolve }
            if targets.depthMS != nil { second.depthAttachment.storeAction = .dontCare }
            encodeMeshPass(commandBuffer, descriptor: second, pipeline: pipeline, slot: slot, cullPass: UInt32(CULL_PASS_SECOND), hiz: targets.hiz, label: "Pass 2 (Hi-Z tested)")
        } else {
            encodeMeshPass(commandBuffer, descriptor: first, pipeline: pipeline, slot: slot, cullPass: UInt32(CULL_PASS_SINGLE), hiz: targets.hiz, label: "Meshlets")
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
                                slot: Int, cullPass: UInt32, hiz: MTLTexture, label: String) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = label
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(settings.wireframe ? .lines : .fill)

        var pass = cullPass
        encoder.setObjectBuffer(uniformBuffers[slot], offset: 0, index: Int(BUFFER_UNIFORMS))
        encoder.setObjectBuffer(gpuMesh.meshlets, offset: 0, index: Int(BUFFER_MESHLETS))
        encoder.setObjectBuffer(statsBuffers[slot], offset: 0, index: Int(BUFFER_STATS))
        encoder.setObjectBytes(&pass, length: MemoryLayout<UInt32>.stride, index: Int(BUFFER_CULL_PASS))
        encoder.setObjectBuffer(visibilityBuffer, offset: 0, index: Int(BUFFER_VISIBILITY))
        encoder.setObjectBuffer(lodBuffer, offset: 0, index: Int(BUFFER_MESHLET_LOD))
        encoder.setObjectTexture(hiz, index: Int(TEXTURE_HIZ))

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

        let t = Targets(renderWidth: renderWidth, renderHeight: renderHeight, outputWidth: outputWidth, outputHeight: outputHeight,
                        samples: samples, color: color, colorMS: colorMS, depth: depth, depthMS: depthMS,
                        upscaled: upscaled, scaler: scaler, hiz: hiz, hizLevels: hizLevels)
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
        let planes = Math.frustumPlanes(from: viewProjection)
        withUnsafeMutablePointer(to: &u.frustumPlanes) { tuple in
            tuple.withMemoryRebound(to: simd_float4.self, capacity: 6) { p in
                for i in 0..<6 { p[i] = planes[i] }
            }
        }
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<Uniforms>.stride)
    }
}
