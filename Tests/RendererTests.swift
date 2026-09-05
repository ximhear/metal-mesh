import Testing
import Foundation
import Metal
import simd
@testable import MetalMesh

@MainActor
struct RendererTests {
    private var device: MTLDevice? { MTLCreateSystemDefaultDevice() }

    private func makeGridMesh(_ n: Int) -> MeshData {
        var vertices: [Vertex] = []
        for y in 0...n {
            for x in 0...n {
                var v = Vertex()
                v.position = SIMD3(Float(x) / Float(n) - 0.5, Float(y) / Float(n) - 0.5, 0)
                v.normal = SIMD3(0, 0, 1)
                vertices.append(v)
            }
        }
        var indices: [UInt32] = []
        for y in 0..<n {
            for x in 0..<n {
                let i = UInt32(y * (n + 1) + x)
                indices += [i, i + 1, i + UInt32(n + 2), i, i + UInt32(n + 2), i + UInt32(n + 1)]
            }
        }
        return MeshData(vertices: vertices, indices: indices, boundsMin: SIMD3(-0.5, -0.5, 0), boundsMax: SIMD3(0.5, 0.5, 0))
    }

    private struct Target {
        let color: MTLTexture
        let pass: MTLRenderPassDescriptor
        let size: Int
    }

    private func makeTarget(device: MTLDevice, size: Int = 256) throws -> Target {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.colorPixelFormat, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.depthPixelFormat, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        let color = try #require(device.makeTexture(descriptor: colorDesc))
        let depth = try #require(device.makeTexture(descriptor: depthDesc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        return Target(color: color, pass: pass, size: size)
    }

    /// 클리어 색과 다른 픽셀 비율 (0…1)
    private func coverage(of target: Target) -> Double {
        let size = target.size
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        target.color.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        // clear 0.11 (linear) → sRGB 인코딩 후 약 92
        var drawn = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = Int(pixels[i]), g = Int(pixels[i + 1]), r = Int(pixels[i + 2])
            if abs(r - 92) > 6 || abs(g - 92) > 6 || abs(b - 99) > 8 { drawn += 1 }
        }
        return Double(drawn) / Double(size * size)
    }

    @Test func pipelineBuildsOnThisDevice() throws {
        let device = try #require(self.device)
        try #require(device.supportsFamily(.metal3))
        let meshlets = MeshletBuilder.build(makeGridMesh(4))
        let renderer = try Renderer(device: device, mesh: meshlets)
        #expect(renderer.stats.meshletCount == meshlets.meshlets.count)
    }

    @Test func rendersFlatGridFacingCamera() throws {
        let device = try #require(self.device)
        let mesh = makeGridMesh(8)
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        renderer.camera.yaw = 0
        renderer.camera.pitch = 0
        let target = try makeTarget(device: device)
        let visible = renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        #expect(visible == renderer.stats.meshletCount)
        let c = coverage(of: target)
        #expect(c > 0.2 && c < 0.9, "coverage \(c)")
    }

    @Test func coneCullingRemovesBackfacingGrid() throws {
        let device = try #require(self.device)
        let mesh = makeGridMesh(8)
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        renderer.camera.yaw = .pi     // 뒤에서 본다 → 평면 노멀(+z)이 카메라 반대
        renderer.camera.pitch = 0
        let target = try makeTarget(device: device)

        renderer.settings.cullingEnabled = true
        let culled = renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        #expect(culled == 0)
        #expect(coverage(of: target) < 0.01)

        renderer.settings.cullingEnabled = false
        let all = renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        #expect(all == renderer.stats.meshletCount)
        #expect(coverage(of: target) > 0.2)
    }

    @Test func rendersBunnyWithCulling() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("stanford-bunny/stanford-bunny.obj"))
        let meshlets = MeshletBuilder.build(mesh)
        let renderer = try Renderer(device: device, mesh: meshlets)
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        let target = try makeTarget(device: device)

        let visible = try #require(renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true))
        #expect(visible > 0)
        #expect(visible < meshlets.meshlets.count, "닫힌 메시는 일부 메시렛이 뒷면으로 컬링돼야 한다")
        let c = coverage(of: target)
        #expect(c > 0.05 && c < 0.8, "coverage \(c)")

        for mode in DebugMode.allCases {
            renderer.settings.debugMode = mode
            renderer.settings.cullingEnabled = false
            let all = renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
            #expect(all == meshlets.meshlets.count)
        }
    }

    @Test func texturedAppleRendersRed() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("food_apple_01/food_apple_01_1k.usdc"))
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh), materials: mesh.materials)
        #expect(renderer.stats.textureCount == 1)
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        let target = try makeTarget(device: device)

        func meanRGB() -> (r: Double, g: Double, b: Double) {
            let size = target.size
            var px = [UInt8](repeating: 0, count: size * size * 4)
            target.color.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for i in stride(from: 0, to: px.count, by: 4) {
                // 배경(약 92,92,99) 제외
                if abs(Int(px[i + 2]) - 92) > 6 || abs(Int(px[i + 1]) - 92) > 6 || abs(Int(px[i]) - 99) > 8 {
                    b += Double(px[i]); g += Double(px[i + 1]); r += Double(px[i + 2]); n += 1
                }
            }
            return n > 0 ? (r / n, g / n, b / n) : (0, 0, 0)
        }

        renderer.settings.texturesEnabled = true
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let textured = meanRGB()
        #expect(textured.r > textured.g * 1.3 && textured.r > textured.b * 1.3, "빨간 사과 텍스처 \(textured)")

        renderer.settings.texturesEnabled = false
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let plain = meanRGB()
        #expect(abs(plain.r - plain.g) < 12, "텍스처 끄면 무채색 \(plain)")
    }

    @Test func indexedColorPNGTextureUploads() async throws {
        // Khronos Duck의 텍스처는 8비트 팔레트 PNG → 정규화 없이는 MTKTextureLoader가 실패한다
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("Duck/Duck.glb"))
        let image = try #require(mesh.materials.compactMap(\.baseColorImage).first)
        #expect(image.bitsPerPixel == 8, "테스트 전제: 팔레트 PNG")
        let normalized = GPUMesh.normalizedRGBA(image)
        #expect(normalized.bitsPerPixel == 32 && normalized.width == image.width)
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh), materials: mesh.materials)
        #expect(renderer.stats.textureCount == 1)
    }

    @Test func frustumPlanesContainCameraTarget() {
        let camera = OrbitCamera()
        camera.frame(center: SIMD3(1, 2, 3), radius: 2)
        camera.aspect = 1.5
        let planes = Math.frustumPlanes(from: camera.projectionMatrix * camera.viewMatrix)
        #expect(planes.count == 6)
        let target = SIMD3<Float>(1, 2, 3)
        for p in planes {
            #expect(simd_dot(SIMD3(p.x, p.y, p.z), target) + p.w > 0)
        }
        // 카메라 뒤쪽 점은 near 평면 밖
        let behind = camera.position + (camera.position - target)
        let near = planes[4]
        #expect(simd_dot(SIMD3(near.x, near.y, near.z), behind) + near.w < 0)
    }
}
