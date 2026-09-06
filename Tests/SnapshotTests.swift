import Testing
import Foundation
import Metal
@testable import MetalMesh
@testable import MeshCore

/// 문서용 스크린샷 생성. `TEST_RUNNER_METALMESH_SNAPSHOTS=1`로 xcodebuild test를 돌리면
/// 테스트 호스트의 임시 폴더 `snapshots/`에 PNG를 쓴다.
@MainActor
struct SnapshotTests {
    struct Shot {
        let file: String
        let name: String
        let mode: DebugMode
        var wireframe = false
        var yaw: Float = 0.6
        var pitch: Float = 0.35
        var zoom: Float = 1
        var lod: Bool = false
        var lodThreshold: Float = 1
        var renderScale: Float = 1
        var msaa: Int = 1
        /// 바닥 + 그림자 + SSAO
        var extras: Bool = false
    }

    static let shots: [Shot] = [
        Shot(file: "stanford-bunny/stanford-bunny.obj", name: "bunny-shaded", mode: .shaded),
        Shot(file: "stanford-bunny/stanford-bunny.obj", name: "bunny-meshlets", mode: .meshlets),
        Shot(file: "lion-noe3d/lion-noe3d.usdz", name: "lion-shaded", mode: .shaded, yaw: 2.4, pitch: 0.25),
        Shot(file: "xyzrgb_dragon/xyzrgb_dragon.obj", name: "dragon-meshlets", mode: .meshlets, yaw: 1.2, pitch: 0.2),
        Shot(file: "armor-man-horse/armor-man-horse.usdz", name: "armor-normals", mode: .normals, yaw: 0.9, pitch: 0.2),
        Shot(file: "teapot/teapot.obj", name: "teapot-wireframe", mode: .shaded, wireframe: true, yaw: 0.8, pitch: 0.4),
        Shot(file: "Camera_01/Camera_01_1k.usdc", name: "camera-textured", mode: .shaded, yaw: 0.7, pitch: 0.3),
        Shot(file: "egyptian-cat/egyptian-cat.usdz", name: "cat-textured", mode: .shaded, yaw: 0.5, pitch: 0.25),
        Shot(file: "Ukulele_01/Ukulele_01_1k.usdc", name: "ukulele-textured", mode: .shaded, yaw: 0.3, pitch: 0.9),
        Shot(file: "Duck/Duck.glb", name: "duck-glb", mode: .shaded, yaw: 0.9, pitch: 0.3),
        Shot(file: "Avocado/Avocado.glb", name: "avocado-glb", mode: .shaded, yaw: 0.6, pitch: 0.3),
        Shot(file: "polypizza-bunny/polypizza-bunny.glb", name: "polypizza-bunny-glb", mode: .shaded, yaw: 0.7, pitch: 0.3),
        // 클러스터 LOD: 같은 거리에서 LOD0 대 자동 선택 (와이어프레임으로 삼각형 밀도 비교)
        Shot(file: "stanford-bunny/stanford-bunny.obj", name: "bunny-lod0-wire", mode: .shaded, wireframe: true, zoom: 1.6, lod: false),
        Shot(file: "stanford-bunny/stanford-bunny.obj", name: "bunny-lod-wire", mode: .shaded, wireframe: true, zoom: 1.6, lod: true, lodThreshold: 2),
        Shot(file: "stanford-bunny/stanford-bunny.obj", name: "bunny-lod-meshlets", mode: .meshlets, zoom: 1.6, lod: true, lodThreshold: 2),
        Shot(file: "xyzrgb_dragon/xyzrgb_dragon.obj", name: "dragon-lod-wire", mode: .shaded, wireframe: true, yaw: 1.2, pitch: 0.2, zoom: 1.6, lod: true, lodThreshold: 2),
        // MetalFX 공간 업스케일 50% / MSAA 4x
        Shot(file: "Camera_01/Camera_01_1k.usdc", name: "camera-metalfx-50", mode: .shaded, yaw: 0.7, pitch: 0.3, renderScale: 0.5),
        Shot(file: "Camera_01/Camera_01_1k.usdc", name: "camera-msaa4", mode: .shaded, yaw: 0.7, pitch: 0.3, msaa: 4),
        // 그림자 + SSAO + 바닥
        Shot(file: "stanford-bunny/stanford-bunny.obj", name: "bunny-shadows", mode: .shaded, yaw: 0.8, pitch: 0.45, extras: true),
        Shot(file: "lion-noe3d/lion-noe3d.usdz", name: "lion-shadows", mode: .shaded, yaw: 2.4, pitch: 0.35, extras: true),
        Shot(file: "Ukulele_01/Ukulele_01_1k.usdc", name: "ukulele-shadows", mode: .shaded, yaw: 0.3, pitch: 0.7, extras: true),
        // 새 PBR 샘플
        Shot(file: "brass_goblets/brass_goblets_1k.usdc", name: "brass-goblets", mode: .shaded, yaw: 0.5, pitch: 0.3, extras: true),
        Shot(file: "Lantern/Lantern.glb", name: "lantern-glb", mode: .shaded, yaw: 0.6, pitch: 0.25, extras: true),
        Shot(file: "ToyCar/ToyCar.glb", name: "toycar-glb", mode: .shaded, yaw: 0.9, pitch: 0.35, extras: true),
        Shot(file: "robot-dog/robot-dog.usdz", name: "robot-dog", mode: .shaded, yaw: 0.6, pitch: 0.3, extras: true),
    ]

    @Test func snapshotProducesImage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var v = [Vertex](repeating: Vertex(), count: 3)
        v[0].position = [-0.5, -0.5, 0]; v[1].position = [0.5, -0.5, 0]; v[2].position = [0, 0.5, 0]
        for i in 0..<3 { v[i].normal = [0, 0, 1] }
        let mesh = MeshData(vertices: v, indices: [0, 1, 2], boundsMin: [-0.5, -0.5, 0], boundsMax: [0.5, 0.5, 0])
        let renderer = try Renderer(device: device, mesh: MeshletBuilder.build(mesh))
        renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
        let image = try #require(renderer.snapshot(width: 64, height: 48))
        #expect(image.width == 64 && image.height == 48)
        let png = try #require(Renderer.pngData(image))
        #expect(png.count > 100)
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func writeDocumentationSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["METALMESH_SNAPSHOTS"] != nil else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for shot in Self.shots {
            let mesh = try await ModelLoader.load(url: samples.appendingPathComponent(shot.file))
            let meshlets = shot.lod ? MeshletLODBuilder.build(mesh) : MeshletBuilder.build(mesh)
            let renderer = try Renderer(device: device, mesh: meshlets, materials: mesh.materials)
            renderer.camera.frame(center: mesh.boundsCenter, radius: mesh.boundsRadius)
            renderer.camera.yaw = shot.yaw
            renderer.camera.pitch = shot.pitch
            renderer.camera.zoom(factor: shot.zoom)
            var settings = RenderSettings(debugMode: shot.mode, cullingEnabled: true, wireframe: shot.wireframe)
            settings.lodEnabled = shot.lod
            settings.lodThresholdPx = shot.lodThreshold
            settings.renderScale = shot.renderScale
            settings.msaaSamples = shot.msaa
            settings.groundEnabled = shot.extras
            settings.shadowsEnabled = shot.extras
            settings.ssaoEnabled = shot.extras
            renderer.settings = settings
            let image = try #require(renderer.snapshot(width: 1200, height: 900))
            let png = try #require(Renderer.pngData(image))
            let url = outDir.appendingPathComponent("\(shot.name).png")
            try png.write(to: url)
            print("SNAPSHOT \(url.path) visible=\(renderer.stats.visibleMeshletCount)/\(renderer.stats.meshletCount) tris=\(mesh.triangleCount) drawnTris=\(renderer.stats.drawnTriangleCount) verts=\(mesh.vertices.count) textures=\(renderer.stats.textureCount) lodLevels=\(renderer.stats.lodLevelCount)")
        }
    }
}
