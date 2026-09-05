import Testing
import Foundation
import simd
@testable import MetalMesh
@testable import MeshCore

struct ModelLoaderTests {
    private func sampleURL(_ relative: String) throws -> URL {
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        return samples.appendingPathComponent(relative)
    }

    @Test func loadsOBJWithGeneratedNormals() async throws {
        let url = try sampleURL("stanford-bunny/stanford-bunny.obj")
        let mesh = try await ModelLoader.load(url: url)
        #expect(mesh.triangleCount == 69_451)
        #expect(mesh.vertices.count > 30_000)
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertices.count })
        // OBJ에 노멀이 없으므로 생성돼야 한다: 단위 길이
        let sampled = stride(from: 0, to: mesh.vertices.count, by: 997).map { mesh.vertices[$0].normal }
        #expect(sampled.allSatisfy { abs(simd_length($0) - 1) < 1e-3 })
        #expect(mesh.boundsRadius > 0)
        #expect(mesh.boundsMin.x < mesh.boundsMax.x)
    }

    @Test func loadsUSDZ() async throws {
        let url = try sampleURL("bust-roza-loewenfeld/bust-roza-loewenfeld.usdz")
        let mesh = try await ModelLoader.load(url: url)
        #expect(mesh.triangleCount == 60_788)
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertices.count })
    }

    @Test func loadsUSDCWithTransforms() async throws {
        let url = try sampleURL("food_apple_01/food_apple_01_1k.usdc")
        let mesh = try await ModelLoader.load(url: url)
        #expect(mesh.triangleCount == 7_012)
        #expect(mesh.boundsRadius > 0)
    }

    @Test func extractsBaseColorTextureFromUSDC() async throws {
        let mesh = try await ModelLoader.load(url: try sampleURL("food_apple_01/food_apple_01_1k.usdc"))
        #expect(mesh.materials.count == 2, "기본 재질 + 사과 재질")
        let apple = try #require(mesh.materials.last)
        let image = try #require(apple.baseColorImage)
        #expect(image.width == 1024 && image.height == 1024)
        #expect(!mesh.triangleMaterials.isEmpty)
        #expect(mesh.triangleMaterials.allSatisfy { $0 == 1 })
    }

    @Test func extractsEmbeddedTexturesFromUSDZ() async throws {
        let mesh = try await ModelLoader.load(url: try sampleURL("egyptian-cat/egyptian-cat.usdz"))
        let textured = mesh.materials.filter { $0.baseColorImage != nil }
        #expect(!textured.isEmpty, "usdz 내장 텍스처를 읽어야 한다")
    }

    @Test func plainOBJHasOnlyDefaultMaterial() async throws {
        let mesh = try await ModelLoader.load(url: try sampleURL("teapot/teapot.obj"))
        #expect(mesh.materials.count == 1)
        #expect(mesh.triangleMaterials.isEmpty)
    }

    @Test func bunnyBuildsIntoMeshlets() async throws {
        let url = try sampleURL("stanford-bunny/stanford-bunny.obj")
        let mesh = try await ModelLoader.load(url: url)
        let meshlets = MeshletBuilder.build(mesh)
        #expect(meshlets.triangleCount == mesh.triangleCount)
        // 126 삼각형 한계 기준 최소 메시렛 수 이상, 정점 한계 때문에 그보다 많다
        #expect(meshlets.meshlets.count >= 69_451 / 126)
        #expect(meshlets.meshlets.count < 69_451 / 10)
    }

    @Test func rejectsUnsupportedExtension() async {
        let url = URL(fileURLWithPath: "/tmp/nothing.fbx")
        await #expect(throws: ModelLoaderError.self) {
            try await ModelLoader.load(url: url)
        }
    }

    @Test func concurrentLoadsAreSerializedSafely() async throws {
        // Phase 1에서 크래시했던 시나리오: USD 파일 여러 개 동시 로드
        let urls = try [
            sampleURL("bust-roza-loewenfeld/bust-roza-loewenfeld.usdz"),
            sampleURL("laocoon/laocoon.usdz"),
            sampleURL("food_apple_01/food_apple_01_1k.usdc"),
            sampleURL("teapot/teapot.obj"),
        ]
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for url in urls { group.addTask { try await ModelLoader.load(url: url).triangleCount } }
            var result: [Int] = []
            for try await c in group { result.append(c) }
            return result
        }
        #expect(counts.sorted() == [6_320, 7_012, 50_106, 60_788])
    }
}
