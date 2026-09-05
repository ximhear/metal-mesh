import Testing
import simd
@testable import MetalMesh

struct MeshletBuilderTests {
    /// n×n 격자 평면 (z=0, 노멀 +z). 삼각형 2·n·n개.
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
                let right = i + 1, up = i + UInt32(n + 1), upRight = up + 1
                indices += [i, right, upRight, i, upRight, up]
            }
        }
        return MeshData(vertices: vertices, indices: indices,
                        boundsMin: .zero, boundsMax: SIMD3(Float(n), Float(n), 0))
    }

    private func triangleSet(_ m: MeshletMesh) -> [[UInt32]] {
        var tris: [[UInt32]] = []
        for meshlet in m.meshlets {
            for t in 0..<Int(meshlet.triangleCount) {
                let base = Int(meshlet.triangleOffset) + t * 3
                let tri = (0..<3).map { k -> UInt32 in
                    let local = Int(m.meshletTriangles[base + k])
                    return m.meshletVertices[Int(meshlet.vertexOffset) + local]
                }
                tris.append(tri)
            }
        }
        return tris
    }

    @Test func preservesEveryTriangleInOrder() {
        let mesh = makeGrid(40)   // 3,200 삼각형 → 여러 메시렛
        let result = MeshletBuilder.build(mesh)
        #expect(result.meshlets.count > 1)
        #expect(result.triangleCount == mesh.triangleCount)

        let original = stride(from: 0, to: mesh.indices.count, by: 3).map { Array(mesh.indices[$0..<$0 + 3]) }
        #expect(triangleSet(result) == original)
    }

    @Test func respectsLimitsAndIndexRanges() {
        let mesh = makeGrid(40)
        let result = MeshletBuilder.build(mesh, maxVertices: 32, maxTriangles: 40)
        for meshlet in result.meshlets {
            #expect(meshlet.vertexCount <= 32)
            #expect(meshlet.triangleCount <= 40)
            #expect(meshlet.triangleCount > 0)
            let triEnd = Int(meshlet.triangleOffset) + Int(meshlet.triangleCount) * 3
            #expect(triEnd <= result.meshletTriangles.count)
            for i in Int(meshlet.triangleOffset)..<triEnd {
                #expect(Int(result.meshletTriangles[i]) < Int(meshlet.vertexCount))
            }
            let vEnd = Int(meshlet.vertexOffset) + Int(meshlet.vertexCount)
            #expect(vEnd <= result.meshletVertices.count)
            for i in Int(meshlet.vertexOffset)..<vEnd {
                #expect(Int(result.meshletVertices[i]) < mesh.vertices.count)
            }
        }
        // 메시렛 간 정점 슬롯이 겹치지 않고 연속이다
        var expectedOffset: UInt32 = 0
        for meshlet in result.meshlets {
            #expect(meshlet.vertexOffset == expectedOffset)
            expectedOffset += UInt32(meshlet.vertexCount)
        }
        #expect(Int(expectedOffset) == result.meshletVertices.count)
    }

    @Test func defaultLimitsMatchShaderHeader() {
        let mesh = makeGrid(40)
        let result = MeshletBuilder.build(mesh)
        for meshlet in result.meshlets {
            #expect(Int(meshlet.vertexCount) <= Int(MESHLET_MAX_VERTICES))
            #expect(Int(meshlet.triangleCount) <= Int(MESHLET_MAX_TRIANGLES))
        }
    }

    @Test func boundingSphereContainsAllVertices() {
        let mesh = makeGrid(20)
        let result = MeshletBuilder.build(mesh)
        for meshlet in result.meshlets {
            for i in Int(meshlet.vertexOffset)..<(Int(meshlet.vertexOffset) + Int(meshlet.vertexCount)) {
                let p = mesh.vertices[Int(result.meshletVertices[i])].position
                #expect(simd_distance(p, meshlet.boundsCenter) <= meshlet.boundsRadius + 1e-4)
            }
            #expect(meshlet.boundsRadius > 0)
        }
    }

    @Test func flatGridHasTightCone() {
        let mesh = makeGrid(10)
        let result = MeshletBuilder.build(mesh)
        for meshlet in result.meshlets {
            #expect(abs(meshlet.coneAxis.z - 1) < 1e-5)
            #expect(meshlet.coneCutoff < 1e-3, "평면 메시렛의 콘은 각도 0")
        }
    }

    @Test func sphereLikeMeshletCannotBeCulled() {
        // 서로 반대 방향을 보는 두 삼각형 → 콘 컬링 불가(cutoff 1)
        var v = [Vertex](repeating: Vertex(), count: 4)
        v[0].position = SIMD3(0, 0, 0); v[1].position = SIMD3(1, 0, 0)
        v[2].position = SIMD3(0, 1, 0); v[3].position = SIMD3(1, 1, 0)
        let mesh = MeshData(vertices: v, indices: [0, 1, 2, 1, 3, 2].reversed().map(UInt32.init) + [0, 1, 2],
                            boundsMin: .zero, boundsMax: SIMD3(1, 1, 0))
        let result = MeshletBuilder.build(mesh)
        #expect(result.meshlets.count == 1)
        #expect(result.meshlets[0].coneCutoff == 1)
    }

    @Test func emptyMeshProducesNoMeshlets() {
        let mesh = MeshData(vertices: [], indices: [], boundsMin: .zero, boundsMax: .zero)
        let result = MeshletBuilder.build(mesh)
        #expect(result.meshlets.isEmpty)
    }
}
