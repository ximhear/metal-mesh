import Testing
import Foundation
import simd
@testable import MetalMesh
@testable import MeshCore

struct MeshletLODTests {
    private func makeGrid(_ n: Int) -> MeshData {
        var vertices: [Vertex] = []
        for y in 0...n {
            for x in 0...n {
                var v = Vertex()
                v.position = SIMD3(Float(x), Float(y), 0)
                v.normal = SIMD3(0, 0, 1)
                v.uv = SIMD2(Float(x) / Float(n), Float(y) / Float(n))
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
        return MeshData(vertices: vertices, indices: indices, boundsMin: .zero, boundsMax: SIMD3(Float(n), Float(n), 0))
    }

    @Test func simplifierHalvesFlatGridWithZeroError() {
        let mesh = makeGrid(20)   // 800 삼각형
        // 외곽 정점만 잠근다
        let n = 20
        let locked: (UInt32) -> Bool = { g in
            let x = Int(g) % (n + 1), y = Int(g) / (n + 1)
            return x == 0 || y == 0 || x == n || y == n
        }
        let result = MeshSimplifier.simplify(vertices: mesh.vertices, triangles: mesh.indices, locked: locked, targetTriangleCount: 400)
        #expect(result.triangles.count / 3 <= 400)
        #expect(result.triangles.count / 3 > 100)
        #expect(result.error < 1e-3, "평면은 기하 오차 없이 단순화된다: \(result.error)")
        // 잠긴 정점은 모두 살아 있어야 한다
        let used = Set(result.triangles)
        for g in 0..<UInt32(mesh.vertices.count) where locked(g) { #expect(used.contains(g)) }
        // 퇴화 삼각형 없음
        for t in stride(from: 0, to: result.triangles.count, by: 3) {
            let a = result.triangles[t], b = result.triangles[t + 1], c = result.triangles[t + 2]
            #expect(a != b && b != c && a != c)
        }
    }

    @Test func lockedVerticesNeverMove() {
        let mesh = makeGrid(12)
        let lockedSet: Set<UInt32> = Set((0..<UInt32(mesh.vertices.count)).filter { $0 % 5 == 0 })
        let result = MeshSimplifier.simplify(vertices: mesh.vertices, triangles: mesh.indices, locked: { lockedSet.contains($0) }, targetTriangleCount: 60)
        let used = Set(result.triangles)
        for g in lockedSet { #expect(used.contains(g), "잠긴 정점 \(g)이 사라졌다") }
    }

    @Test func buildsHierarchyForBunny() async throws {
        let samples = try #require(Bundle.main.url(forResource: "Samples", withExtension: nil))
        let mesh = try await ModelLoader.load(url: samples.appendingPathComponent("stanford-bunny/stanford-bunny.obj"))
        let t0 = Date()
        let result = MeshletLODBuilder.build(mesh)
        let ms = Date().timeIntervalSince(t0) * 1000
        #expect(result.lod.count == result.meshlets.count)
        #expect(result.level0TriangleCount == mesh.triangleCount)
        #expect(result.lodLevelCount >= 4, "레벨 수 \(result.lodLevelCount)")
        // 레벨별 삼각형 수는 줄어들어야 한다
        var perLevel: [Int] = Array(repeating: 0, count: result.lodLevelCount)
        for (m, l) in zip(result.meshlets, result.lod) { perLevel[Int(l.level)] += Int(m.triangleCount) }
        for i in 1..<perLevel.count { #expect(perLevel[i] < perLevel[i - 1], "레벨 \(i): \(perLevel)") }
        // 부모 오차 단조성: 자식 parentError == 부모 error, error 증가
        for l in result.lod where l.parentError < LOD_ERROR_INFINITE {
            #expect(l.parentError > l.error)
        }
        #expect(perLevel.last! < perLevel[0] / 8, "가장 거친 레벨은 원본의 1/8 미만: \(perLevel)")
        print(String(format: "LOD bunny: levels=%d meshlets=%d trisPerLevel=%@ build=%.0fms", result.lodLevelCount, result.meshlets.count, perLevel.description, ms))
    }
}
