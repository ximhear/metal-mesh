import Testing
import Foundation
import Metal
import CoreGraphics
import simd
@testable import MetalMesh
@testable import MeshCore

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

    /// 기하·컬링 테스트는 바닥/그림자/SSAO 없이 메시만 본다
    private func plain(_ renderer: Renderer) {
        renderer.settings.groundEnabled = false
        renderer.settings.shadowsEnabled = false
        renderer.settings.ssaoEnabled = false
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
        let color = try #require(device.makeTexture(descriptor: colorDesc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.clearColor
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
        plain(renderer)
        #expect(renderer.stats.meshletCount == meshlets.meshlets.count)
    }

    @Test func rendersFlatGridFacingCamera() throws {
        let device = try #require(self.device)
        let mesh = makeGridMesh(8)
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        plain(renderer)
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
        plain(renderer)
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
        plain(renderer)
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
            renderer.settings.occlusionEnabled = false
            let all = renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
            #expect(all == meshlets.meshlets.count)
        }
    }

    @Test func texturedAppleRendersRed() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("food_apple_01/food_apple_01_1k.usdc"))
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh), materials: mesh.materials)
        plain(renderer)
        #expect(renderer.stats.textureCount >= 1)
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
        plain(renderer)
        #expect(renderer.stats.textureCount >= 1)
    }

    @Test func meshletStrategyComparisonOnRealModels() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let target = try makeTarget(device: device, size: 128)
        for file in ["stanford-bunny/stanford-bunny.obj", "xyzrgb_dragon/xyzrgb_dragon.obj", "lion-noe3d/lion-noe3d.usdz"] {
            let mesh = try await ModelLoader.load(url: samples.appendingPathComponent(file))
            var report: [String: (count: Int, culled: Double, radius: Float, cutoff: Float, ms: Double)] = [:]
            for (name, strategy) in [("spatialScan", MeshletBuilder.Strategy.spatialScan), ("cluster", .cluster)] {
                let t0 = Date()
                let meshlets = MeshletBuilder.build(mesh, strategy: strategy)
                let ms = Date().timeIntervalSince(t0) * 1000
                let renderer = try Renderer(device: device, mesh: meshlets, materials: mesh.materials)
                plain(renderer)
                renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
                var visibleSum = 0
                var occlusionDrawnSum = 0
                let views = 6
                for i in 0..<views {
                    renderer.camera.yaw = Float(i) / Float(views) * 2 * .pi
                    renderer.settings.occlusionEnabled = false
                    visibleSum += renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true) ?? 0
                    // 오클루전: 비트를 초기화하고 2프레임 그린 뒤(안정 상태) 그린 수를 잰다
                    renderer.settings.occlusionEnabled = true
                    renderer.resetVisibility()
                    renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
                    occlusionDrawnSum += renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true) ?? 0
                }
                let culled = 1 - Double(visibleSum) / Double(meshlets.meshlets.count * views)
                let culledWithOcclusion = 1 - Double(occlusionDrawnSum) / Double(meshlets.meshlets.count * views)
                let radius = meshlets.meshlets.map(\.boundsRadius).reduce(0, +) / Float(meshlets.meshlets.count)
                let cutoff = meshlets.meshlets.map(\.coneCutoff).reduce(0, +) / Float(meshlets.meshlets.count)
                report[name] = (meshlets.meshlets.count, culled, radius, cutoff, ms)
                print(String(format: "STRATEGY %@ %@: meshlets=%d culled=%.1f%% +occlusion=%.1f%% meanRadius=%.4f meanCutoff=%.3f build=%.0fms",
                             (file as NSString).lastPathComponent, name, meshlets.meshlets.count, culled * 100, culledWithOcclusion * 100, radius, cutoff, ms))
                #expect(culledWithOcclusion >= culled - 0.001, "\(file) \(name): 오클루전이 그리는 수를 늘리면 안 된다")
            }
            let scan = try #require(report["spatialScan"]), cluster = try #require(report["cluster"])
            #expect(cluster.count <= Int(Double(scan.count) * 1.25), "\(file): 메시렛 수가 스캔 대비 25% 이상 늘면 안 된다")
            #expect(cluster.culled >= scan.culled, "\(file): 컬링률은 좋아져야 한다")
            #expect(cluster.radius <= scan.radius, "\(file): 경계 구가 작아져야 한다")
        }
    }

    /// z 위치가 다른 평면 두 장. 앞 평면이 뒤 평면을 완전히 가린다.
    private func makeTwoPlanes(_ n: Int) -> MeshData {
        var front = makeGridMesh(n)                       // z = 0, 카메라(+z)에서 가까움
        var back = makeGridMesh(n)
        for i in back.vertices.indices {
            // 경계 구(AABB 8꼭짓점)를 투영해도 앞 평면 화면 영역 안에 머물도록 충분히 작고 가깝게
            back.vertices[i].position *= SIMD3(0.3, 0.3, 1)
            back.vertices[i].position.z = -0.3
        }
        let base = UInt32(front.vertices.count)
        front.vertices += back.vertices
        front.indices += back.indices.map { $0 + base }
        front.boundsMin = SIMD3(-0.5, -0.5, -0.3)
        front.boundsMax = SIMD3(0.5, 0.5, 0)
        return front
    }

    @Test func hiZOcclusionCullsHiddenPlane() throws {
        let device = try #require(self.device)
        let mesh = makeTwoPlanes(8)
        let meshlets = MeshletBuilder.build(mesh, maxVertices: 32, maxTriangles: 40)
        let renderer = try Renderer(device: device, mesh: meshlets)
        plain(renderer)
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        renderer.camera.yaw = 0
        renderer.camera.pitch = 0
        renderer.settings.cullingEnabled = false   // 콘 컬링 배제, 오클루전만 본다
        let target = try makeTarget(device: device)

        renderer.settings.occlusionEnabled = false
        let all = renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        #expect(all == meshlets.meshlets.count)
        let referenceCoverage = coverage(of: target)

        renderer.settings.occlusionEnabled = true
        // 1프레임: 1패스가 전부 그리고 2패스가 비트 정리 → 2프레임부터 뒤 평면이 빠진다
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let drawn = try #require(renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true))
        let backMeshlets = meshlets.meshlets.filter { $0.boundsCenter.z < -0.15 }.count
        #expect(backMeshlets > 0)
        #expect(renderer.stats.occludedMeshletCount == backMeshlets, "뒤 평면 메시렛 전부가 가려져야 한다: \(renderer.stats.occludedMeshletCount) vs \(backMeshlets)")
        #expect(drawn == meshlets.meshlets.count - backMeshlets)
        #expect(abs(coverage(of: target) - referenceCoverage) < 0.002, "가려진 것만 빠졌으니 이미지는 같아야 한다")
    }

    @Test func hiZOcclusionKeepsBunnyImageIdentical() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("stanford-bunny/stanford-bunny.obj"))
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        plain(renderer)
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        let target = try makeTarget(device: device)
        func pixels() -> [UInt8] {
            var px = [UInt8](repeating: 0, count: target.size * target.size * 4)
            target.color.getBytes(&px, bytesPerRow: target.size * 4, from: MTLRegionMake2D(0, 0, target.size, target.size), mipmapLevel: 0)
            return px
        }
        renderer.settings.occlusionEnabled = false
        let visibleNoOcclusion = try #require(renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true))
        let reference = pixels()

        renderer.settings.occlusionEnabled = true
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let drawn = try #require(renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true))
        let occluded = pixels()
        #expect(renderer.stats.occludedMeshletCount > 0, "닫힌 메시라 뒷면 일부는 콘을 통과해도 가려져야 한다")
        #expect(drawn < visibleNoOcclusion)
        var differing = 0
        for i in stride(from: 0, to: reference.count, by: 4) {
            if abs(Int(reference[i]) - Int(occluded[i])) > 2 || abs(Int(reference[i + 1]) - Int(occluded[i + 1])) > 2 || abs(Int(reference[i + 2]) - Int(occluded[i + 2])) > 2 { differing += 1 }
        }
        let ratio = Double(differing) / Double(target.size * target.size)
        #expect(ratio < 0.002, "오클루전은 보이는 픽셀을 바꾸면 안 된다 (다른 픽셀 비율 \(ratio))")
    }

    @Test func lodDrawsFewerTrianglesFarAwayAndMatchesNearby() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("stanford-bunny/stanford-bunny.obj"))
        let lodMesh = MeshletLODBuilder.build(mesh)
        let renderer = try Renderer(device: device, mesh: lodMesh, materials: mesh.materials)
        plain(renderer)
        renderer.settings.cullingEnabled = false
        renderer.settings.occlusionEnabled = false
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        let target = try makeTarget(device: device, size: 256)
        func pixels() -> [UInt8] {
            var px = [UInt8](repeating: 0, count: target.size * target.size * 4)
            target.color.getBytes(&px, bytesPerRow: target.size * 4, from: MTLRegionMake2D(0, 0, target.size, target.size), mipmapLevel: 0)
            return px
        }
        // 가까이: LOD 켬/끔 이미지가 거의 같아야 한다 (허용 오차 0.5px)
        renderer.settings.lodEnabled = false
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let lod0Tris = renderer.stats.drawnTriangleCount
        let reference = pixels()
        #expect(lod0Tris == mesh.triangleCount)

        renderer.settings.lodEnabled = true
        renderer.settings.lodThresholdPx = 0.5
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let nearTris = renderer.stats.drawnTriangleCount
        let near = pixels()
        var differing = 0
        for i in stride(from: 0, to: reference.count, by: 4) where abs(Int(reference[i]) - Int(near[i])) > 8 || abs(Int(reference[i + 1]) - Int(near[i + 1])) > 8 { differing += 1 }
        let ratio = Double(differing) / Double(target.size * target.size)
        #expect(ratio < 0.02, "가까운 거리 LOD 이미지 차이 \(ratio)")
        #expect(nearTris <= lod0Tris)

        // 멀리: 삼각형이 크게 줄어야 한다
        renderer.camera.zoom(factor: 1 / 8)
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let farTris = renderer.stats.drawnTriangleCount
        #expect(farTris < lod0Tris / 4, "멀리서 \(farTris) vs 원본 \(lod0Tris)")
        #expect(farTris > 0)
        print("LOD render: lod0=\(lod0Tris) near=\(nearTris) far(8x)=\(farTris) levels=\(lodMesh.lodLevelCount)")
    }

    @Test func metalFXUpscaleAndMSAAProduceSimilarImages() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("stanford-bunny/stanford-bunny.obj"))
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        plain(renderer)
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        let target = try makeTarget(device: device, size: 256)
        func pixels() -> [UInt8] {
            var px = [UInt8](repeating: 0, count: target.size * target.size * 4)
            target.color.getBytes(&px, bytesPerRow: target.size * 4, from: MTLRegionMake2D(0, 0, target.size, target.size), mipmapLevel: 0)
            return px
        }
        func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var sum = 0
            for i in stride(from: 0, to: a.count, by: 4) { sum += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) }
            return Double(sum) / Double(a.count / 4 * 3)
        }
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let reference = pixels()
        #expect(renderer.stats.renderWidth == 256 && renderer.stats.upscalerActive == false)

        // MSAA 4x: 같은 장면, 가장자리만 부드러워진다
        renderer.settings.msaaSamples = 4
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let msaa = pixels()
        #expect(meanAbsDiff(reference, msaa) < 6, "MSAA 차이 \(meanAbsDiff(reference, msaa))")
        #expect(coverage(of: target) > 0.05)

        // MetalFX 공간 업스케일 (50% → 100%)
        renderer.settings.msaaSamples = 1
        renderer.settings.renderScale = 0.5
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let upscaled = pixels()
        if Renderer.supportsMetalFX {
            #expect(renderer.stats.upscalerActive)
            #expect(renderer.stats.renderWidth == 128 && renderer.stats.outputWidth == 256)
        }
        #expect(meanAbsDiff(reference, upscaled) < 12, "업스케일 차이 \(meanAbsDiff(reference, upscaled))")
        #expect(coverage(of: target) > 0.05)
        print("METALFX msaaDiff=\(meanAbsDiff(reference, msaa)) upscaleDiff=\(meanAbsDiff(reference, upscaled)) supported=\(Renderer.supportsMetalFX)")

        // 다시 100%: 참조와 동일해야 한다
        renderer.settings.renderScale = 1
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        #expect(meanAbsDiff(reference, pixels()) < 0.5)
    }

    @Test func shadowsAndSSAODarkenTheImage() async throws {
        let device = try #require(self.device)
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("stanford-bunny/stanford-bunny.obj"))
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        renderer.camera.pitch = 0.6   // 위에서 봐서 바닥 그림자가 보이게
        let target = try makeTarget(device: device, size: 256)
        func meanLuma() -> Double {
            var px = [UInt8](repeating: 0, count: target.size * target.size * 4)
            target.color.getBytes(&px, bytesPerRow: target.size * 4, from: MTLRegionMake2D(0, 0, target.size, target.size), mipmapLevel: 0)
            var sum = 0.0
            for i in stride(from: 0, to: px.count, by: 4) { sum += 0.114 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.299 * Double(px[i + 2]) }
            return sum / Double(px.count / 4)
        }
        _ = try renderer.makeShadowPipeline()   // 깊이 전용 메시 파이프라인이 만들어져야 한다
        renderer.settings.groundEnabled = true
        renderer.settings.shadowsEnabled = false
        renderer.settings.ssaoEnabled = false
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let base = meanLuma()
        #expect(coverage(of: target) > 0.3, "바닥이 화면을 채워야 한다")

        renderer.settings.shadowsEnabled = true
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let shadowed = meanLuma()
        #expect(shadowed < base - 0.2, "그림자가 이미지를 어둡게 해야 한다: \(base) → \(shadowed)")

        renderer.settings.ssaoEnabled = true
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        let ao = meanLuma()
        #expect(ao < shadowed, "SSAO가 접촉부를 더 어둡게: \(shadowed) → \(ao)")
        print("SHADOW luma base=\(base) shadows=\(shadowed) +ssao=\(ao)")

        // 바닥 없이도 렌더 정상
        renderer.settings.groundEnabled = false
        renderer.renderFrame(passDescriptor: target.pass, drawable: nil, waitUntilCompleted: true)
        #expect(coverage(of: target) > 0.05)
    }

    @Test func onePixelTextureDoesNotRequestMipmaps() throws {
        // iPhone 실기기 크래시 회귀: 1×1 텍스처 + generateMipmaps → "[tex mipmapLevelCount](1) must be > 1"
        let device = try #require(self.device)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(ctx.makeImage())
        var material = MaterialData(name: "tiny")
        material.baseColorImage = image
        material.normalImage = image
        let mesh = MeshletBuilder.build(makeGridMesh(2))
        let gpu = try GPUMesh(device: device, mesh: mesh, materials: [material])
        #expect(gpu.textureCount == 1, "같은 CGImage는 한 번만 올린다")
        #expect(gpu.textures.allSatisfy { $0.mipmapLevelCount == 1 })
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

@MainActor
struct OrbitCameraTests {
    @Test func yawPitchMatchSphericalPosition() {
        let camera = OrbitCamera()
        camera.frame(center: .zero, radius: 1)
        camera.yaw = 0.5
        camera.pitch = 0.3
        let expected = SIMD3(cos(0.3) * sin(0.5), sin(0.3), cos(0.3) * cos(0.5)) * camera.distance
        #expect(simd_distance(camera.position, expected) < 1e-4)
        #expect(camera.up.y > 0.9, "기본 자세는 수평")
    }

    @Test func trackballRotationHasNoGimbalLock() {
        let camera = OrbitCamera()
        camera.frame(center: .zero, radius: 1)
        camera.yaw = 0
        camera.pitch = 0
        // 세로 드래그를 계속하면 극점을 지나 반대편으로 넘어가야 한다 (각도 제한 없음)
        for _ in 0..<40 { camera.rotate(deltaYaw: 0, deltaPitch: 0.1) }   // 총 4 rad ≈ 229°
        let p = simd_normalize(camera.position - camera.target)
        #expect(p.z < 0, "극점을 넘어 뒤쪽(-z)으로 넘어갔어야 한다: \(p)")
        #expect(abs(simd_length(camera.position - camera.target) - camera.distance) < 1e-3)
        // 회전 후에도 뷰 행렬이 유효(직교 기저)
        let view = camera.viewMatrix
        let r = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let u = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        #expect(abs(simd_dot(r, u)) < 1e-4)
    }

    @Test func horizontalDragRotatesAroundUp() {
        let camera = OrbitCamera()
        camera.frame(center: .zero, radius: 1)
        camera.yaw = 0
        camera.pitch = 0
        let before = camera.position
        camera.rotate(deltaYaw: 0.5, deltaPitch: 0)
        let after = camera.position
        #expect(abs(after.y - before.y) < 1e-4, "가로 드래그는 높이를 바꾸지 않는다")
        #expect(after.x > 0, "yaw 증가 → +x 쪽으로")
    }
}
