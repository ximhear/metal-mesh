import Foundation
import simd

/// 메시렛으로 분할된 메시. GPU 버퍼로 그대로 올라간다.
struct MeshletMesh: Sendable {
    var vertices: [Vertex]
    var meshlets: [Meshlet]
    /// 메시렛별 전역 정점 인덱스 (메시렛의 vertexOffset부터 vertexCount개)
    var meshletVertices: [UInt32]
    /// 메시렛 로컬 인덱스 (0..<vertexCount), 삼각형당 3개
    var meshletTriangles: [UInt8]

    var triangleCount: Int { meshlets.reduce(0) { $0 + Int($1.triangleCount) } }
}

/// 삼각형을 공간 순서(Morton 코드)로 정렬한 뒤 순서대로 훑어 메시렛으로 묶는다.
/// 정렬 덕분에 메시렛이 공간적으로 뭉쳐 경계 구가 작고 노멀 콘이 좁아져 컬링 효율이 높다.
/// (meshoptimizer의 buildMeshletsScan + 공간 정렬 조합에 해당. 최적 클러스터링은 아니다.)
enum MeshletBuilder {
    static func build(
        _ mesh: MeshData,
        maxVertices: Int = Int(MESHLET_MAX_VERTICES),
        maxTriangles: Int = Int(MESHLET_MAX_TRIANGLES),
        spatialSort: Bool = true
    ) -> MeshletMesh {
        precondition(maxVertices <= 256 && maxTriangles <= 512, "Metal 메시 셰이더 한계 초과")
        precondition(maxVertices >= 3 && maxTriangles >= 1)

        let vertices = mesh.vertices
        let indices = spatialSort ? sortedByMortonCode(mesh) : mesh.indices
        let triangleTotal = indices.count / 3

        var result = MeshletMesh(vertices: vertices, meshlets: [], meshletVertices: [], meshletTriangles: [])
        result.meshlets.reserveCapacity(triangleTotal / maxTriangles + 1)
        result.meshletVertices.reserveCapacity(triangleTotal * 3 / 2)
        result.meshletTriangles.reserveCapacity(triangleTotal * 3)

        // 전역 정점 → 현재 메시렛의 로컬 인덱스. -1이면 없음.
        var localIndex = [Int16](repeating: -1, count: vertices.count)
        var current = Meshlet()
        current.vertexOffset = 0
        current.triangleOffset = 0
        var currentTriangleStart = 0   // 삼각형 번호 기준 시작 (경계 계산용)

        func flush(endTriangle: Int) {
            guard current.triangleCount > 0 else { return }
            computeBounds(&current, vertices: vertices, indices: indices,
                          triangleRange: currentTriangleStart..<endTriangle)
            // 다음 메시렛 준비: 사용한 로컬 인덱스 초기화
            let start = Int(current.vertexOffset)
            for i in start..<(start + Int(current.vertexCount)) {
                localIndex[Int(result.meshletVertices[i])] = -1
            }
            result.meshlets.append(current)
            current = Meshlet()
            current.vertexOffset = UInt32(result.meshletVertices.count)
            current.triangleOffset = UInt32(result.meshletTriangles.count)
            currentTriangleStart = endTriangle
        }

        for t in 0..<triangleTotal {
            let a = indices[t * 3], b = indices[t * 3 + 1], c = indices[t * 3 + 2]
            let newVertices = (localIndex[Int(a)] < 0 ? 1 : 0)
                + (localIndex[Int(b)] < 0 && b != a ? 1 : 0)
                + (localIndex[Int(c)] < 0 && c != a && c != b ? 1 : 0)

            if Int(current.vertexCount) + newVertices > maxVertices
                || Int(current.triangleCount) + 1 > maxTriangles {
                flush(endTriangle: t)
            }

            for v in [a, b, c] {
                if localIndex[Int(v)] < 0 {
                    localIndex[Int(v)] = Int16(current.vertexCount)
                    result.meshletVertices.append(v)
                    current.vertexCount += 1
                }
                result.meshletTriangles.append(UInt8(localIndex[Int(v)]))
            }
            current.triangleCount += 1
        }
        flush(endTriangle: triangleTotal)
        return result
    }

    /// 삼각형 무게중심의 Morton 코드(30비트)로 삼각형 순서를 재배열한 인덱스 배열을 돌려준다.
    static func sortedByMortonCode(_ mesh: MeshData) -> [UInt32] {
        let triangleTotal = mesh.indices.count / 3
        guard triangleTotal > 1 else { return mesh.indices }
        let extent = mesh.boundsMax - mesh.boundsMin
        let scale = SIMD3<Float>(
            extent.x > 0 ? 1023 / extent.x : 0,
            extent.y > 0 ? 1023 / extent.y : 0,
            extent.z > 0 ? 1023 / extent.z : 0
        )
        var keys = [(key: UInt32, triangle: Int)]()
        keys.reserveCapacity(triangleTotal)
        for t in 0..<triangleTotal {
            let a = mesh.vertices[Int(mesh.indices[t * 3])].position
            let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])].position
            let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])].position
            let q = ((a + b + c) / 3 - mesh.boundsMin) * scale
            let x = UInt32(min(max(q.x, 0), 1023)), y = UInt32(min(max(q.y, 0), 1023)), z = UInt32(min(max(q.z, 0), 1023))
            keys.append((morton(x) | morton(y) << 1 | morton(z) << 2, t))
        }
        keys.sort { $0.key < $1.key }
        var sorted = [UInt32]()
        sorted.reserveCapacity(mesh.indices.count)
        for (_, t) in keys {
            sorted.append(mesh.indices[t * 3])
            sorted.append(mesh.indices[t * 3 + 1])
            sorted.append(mesh.indices[t * 3 + 2])
        }
        return sorted
    }

    /// 10비트 정수를 3비트 간격으로 펼친다
    private static func morton(_ v: UInt32) -> UInt32 {
        var x = v & 0x3FF
        x = (x | x << 16) & 0x030000FF
        x = (x | x << 8) & 0x0300F00F
        x = (x | x << 4) & 0x030C30C3
        x = (x | x << 2) & 0x09249249
        return x
    }

    /// 경계 구(AABB 중심 + 최대 거리)와 노멀 콘(meshoptimizer 규약)을 계산한다.
    private static func computeBounds(_ meshlet: inout Meshlet, vertices: [Vertex], indices: [UInt32], triangleRange: Range<Int>) {
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(triangleRange.count)

        for t in triangleRange {
            let p0 = vertices[Int(indices[t * 3])].position
            let p1 = vertices[Int(indices[t * 3 + 1])].position
            let p2 = vertices[Int(indices[t * 3 + 2])].position
            minP = simd_min(minP, simd_min(p0, simd_min(p1, p2)))
            maxP = simd_max(maxP, simd_max(p0, simd_max(p1, p2)))
            let n = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(n)
            if len > 0 { normals.append(n / len) }
        }

        let center = (minP + maxP) * 0.5
        var radius: Float = 0
        for t in triangleRange {
            for k in 0..<3 {
                radius = max(radius, simd_distance(center, vertices[Int(indices[t * 3 + k])].position))
            }
        }
        meshlet.boundsCenter = center
        meshlet.boundsRadius = radius

        // 콘: 평균 노멀 방향, 모든 삼각형 노멀과의 최소 코사인으로 각도 결정
        var axis = normals.reduce(SIMD3<Float>.zero, +)
        let axisLength = simd_length(axis)
        guard axisLength > 0 else {
            meshlet.coneAxis = SIMD3(0, 0, 1)
            meshlet.coneCutoff = 1
            return
        }
        axis /= axisLength
        let minDot = normals.reduce(Float(1)) { min($0, simd_dot(axis, $1)) }
        meshlet.coneAxis = axis
        // minDot ≤ 0.1이면 반구 이상으로 퍼져 있어 컬링 불가 → 1.0
        meshlet.coneCutoff = minDot <= 0.1 ? 1 : (1 - minDot * minDot).squareRoot()
    }
}
