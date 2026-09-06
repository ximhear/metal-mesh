import Foundation
import simd

/// 클러스터 LOD 계층 (Nanite 방식의 단순화 버전).
///
/// 레벨 L의 메시렛을 인접한 것끼리 ≤4개 그룹으로 묶고, 그룹 경계 정점을 잠근 채 삼각형을 절반으로 단순화한 뒤
/// 다시 메시렛으로 나눠 레벨 L+1을 만든다. 그룹의 (경계 구, 오차)를 자식 메시렛의 parent와 부모 메시렛의 self에
/// 똑같이 기록하면 GPU가 "self 오차 ≤ 임계값 < parent 오차"만으로 크랙 없는 컷을 고른다.
public enum MeshletLODBuilder {
    public struct Options: Sendable {
        public var maxLevels = 12
        public var groupSize = 4
        /// 그룹 단순화가 이 비율 이상 삼각형을 남기면 더 거친 레벨을 만들지 않는다 (루트로 확정)
        public var minReduction: Float = 0.8
        public init() {}
    }

    /// LOD0 메시렛을 만들고 그 위에 계층을 쌓는다.
    public static func build(_ mesh: MeshData, options: Options = Options()) -> MeshletMesh {
        build(mesh, options: options, cancellationCheck: {})
    }

    public static func build(_ mesh: MeshData, options: Options = Options(), cancellationCheck: () throws -> Void) rethrows -> MeshletMesh {
        try cancellationCheck()
        var result = try MeshletBuilder.build(mesh, strategy: .cluster, cancellationCheck: cancellationCheck)
        guard !result.meshlets.isEmpty else { return result }
        let vertices = mesh.vertices

        // LOD0: 자기 경계 = 메시렛 경계 구, 오차 0, 부모 없음
        result.lod = result.meshlets.map { m in
            var l = MeshletLOD()
            l.center = m.boundsCenter; l.radius = m.boundsRadius
            l.error = 0; l.level = 0
            l.parentError = LOD_ERROR_INFINITE
            return l
        }

        var current = Array(0..<result.meshlets.count)   // 현재 레벨의 메시렛 인덱스
        var level: UInt32 = 0
        while current.count > 1 && Int(level) < options.maxLevels {
            try cancellationCheck()
            // 현재 레벨 삼각형 집합에 대한 정점 → 메시렛 인접, 에지 사용 수 (경계 잠금용)
            var vertexMeshlets: [UInt32: [Int32]] = [:]
            var edgeUse: [UInt64: Int32] = [:]
            var meshletTriangles: [Int: [UInt32]] = [:]
            for mi in current {
                let tris = result.triangles(ofMeshlet: mi)
                meshletTriangles[mi] = tris
                var seenV = Set<UInt32>()
                for t in stride(from: 0, to: tris.count, by: 3) {
                    for k in 0..<3 {
                        let a = tris[t + k], b = tris[t + (k + 1) % 3]
                        edgeUse[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1
                        if seenV.insert(a).inserted { vertexMeshlets[a, default: []].append(Int32(mi)) }
                    }
                }
            }
            let groups = groupMeshlets(current, vertexMeshlets: vertexMeshlets, meshlets: result.meshlets, groupSize: options.groupSize)

            var next: [Int] = []
            for group in groups {
                try cancellationCheck()
                let groupSet = Set(group.map(Int32.init))
                var tris: [UInt32] = []
                for mi in group { tris += meshletTriangles[mi]! }
                let triCount = tris.count / 3
                // 잠금: 그룹 밖 메시렛과 공유하는 정점, 메시 외곽 에지의 정점
                var lockedVertices = Set<UInt32>()
                for t in stride(from: 0, to: tris.count, by: 3) {
                    for k in 0..<3 {
                        let a = tris[t + k], b = tris[t + (k + 1) % 3]
                        if edgeUse[UInt64(min(a, b)) << 32 | UInt64(max(a, b))] == 1 { lockedVertices.insert(a); lockedVertices.insert(b) }
                        if let owners = vertexMeshlets[a], owners.contains(where: { !groupSet.contains($0) }) { lockedVertices.insert(a) }
                    }
                }
                let target = max(triCount / 2, 1)
                let simplified = MeshSimplifier.simplify(vertices: vertices, triangles: tris,
                                                         locked: { lockedVertices.contains($0) },
                                                         targetTriangleCount: target)
                let reduced = simplified.triangles.count / 3
                // 줄어들지 않으면 이 그룹은 루트로 남긴다
                if reduced == 0 || Float(reduced) > Float(triCount) * options.minReduction { continue }

                // 그룹 경계 구: 자식 구들을 감싸는 구
                let (center, radius) = enclosingSphere(group.map { (result.lod[$0].center, result.lod[$0].radius) })
                let childError = group.map { result.lod[$0].error }.max() ?? 0
                let groupError = max(simplified.error, childError) + 1e-7   // 단조 증가 보장

                // 자식의 parent 갱신
                for mi in group {
                    result.lod[mi].parentCenter = center
                    result.lod[mi].parentRadius = radius
                    result.lod[mi].parentError = groupError
                }
                // 단순화 결과를 새 메시렛으로
                let material = result.meshlets[group[0]].materialIndex
                let newIndices = appendMeshlets(from: simplified.triangles, material: material, vertices: vertices, into: &result)
                for ni in newIndices {
                    var l = MeshletLOD()
                    l.center = center; l.radius = radius
                    l.error = groupError; l.level = level + 1
                    l.parentError = LOD_ERROR_INFINITE
                    result.lod.append(l)
                    next.append(ni)
                }
            }
            if next.isEmpty { break }
            current = next
            level += 1
        }
        return result
    }

    public static func buildAsync(_ mesh: MeshData, options: Options = Options()) async throws -> MeshletMesh {
        try await BackgroundWork.run {
            try build(mesh, options: options, cancellationCheck: Task.checkCancellation)
        }
    }

    // MARK: - 그룹화

    /// 정점 공유가 많은 인접 메시렛끼리(같은 재질) ≤ groupSize 그룹으로 묶는다.
    private static func groupMeshlets(_ current: [Int], vertexMeshlets: [UInt32: [Int32]], meshlets: [Meshlet], groupSize: Int) -> [[Int]] {
        // 인접 가중치
        var weight: [Int: [Int: Int]] = [:]
        for (_, owners) in vertexMeshlets where owners.count > 1 {
            for i in 0..<owners.count {
                for j in (i + 1)..<owners.count {
                    let a = Int(owners[i]), b = Int(owners[j])
                    weight[a, default: [:]][b, default: 0] += 1
                    weight[b, default: [:]][a, default: 0] += 1
                }
            }
        }
        var assigned = Set<Int>()
        var groups: [[Int]] = []
        // 공간 순서(경계 구 중심 Morton 근사: x,y,z 정렬 대신 x 우선 정렬)로 시드를 돌며 그리디
        let ordered = current.sorted { meshlets[$0].boundsCenter.x < meshlets[$1].boundsCenter.x }
        for seed in ordered where !assigned.contains(seed) {
            var group = [seed]
            assigned.insert(seed)
            let material = meshlets[seed].materialIndex
            while group.count < groupSize {
                // 그룹 전체와 가장 많이 연결된 미배정 이웃
                var best = -1, bestW = 0
                for m in group {
                    for (n, w) in weight[m] ?? [:] where !assigned.contains(n) && meshlets[n].materialIndex == material {
                        if w > bestW { bestW = w; best = n }
                    }
                }
                guard best >= 0 else { break }
                group.append(best); assigned.insert(best)
            }
            groups.append(group)
        }
        return groups
    }

    // MARK: - 유틸

    private static func enclosingSphere(_ spheres: [(SIMD3<Float>, Float)]) -> (SIMD3<Float>, Float) {
        guard var (c, r) = spheres.first else { return (.zero, 0) }
        for (c2, r2) in spheres.dropFirst() {
            let d = simd_distance(c, c2)
            if d + r2 <= r { continue }            // 이미 포함
            if d + r <= r2 { c = c2; r = r2; continue }
            let newR = (d + r + r2) * 0.5
            c = c + (c2 - c) * ((newR - r) / max(d, 1e-8))
            r = newR
        }
        return (c, r)
    }

    /// 삼각형 목록을 압축 정점으로 클러스터링한 뒤 전역 인덱스로 되돌려 result에 덧붙인다. 새 메시렛 인덱스를 돌려준다.
    private static func appendMeshlets(from triangles: [UInt32], material: UInt32, vertices: [Vertex], into result: inout MeshletMesh) -> [Int] {
        var globalOf: [UInt32] = []
        var localOf: [UInt32: UInt32] = [:]
        var local = [UInt32](); local.reserveCapacity(triangles.count)
        var localVertices: [Vertex] = []
        for g in triangles {
            if let l = localOf[g] { local.append(l) } else {
                let l = UInt32(globalOf.count); globalOf.append(g); localOf[g] = l; local.append(l)
                localVertices.append(vertices[Int(g)])
            }
        }
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude), maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in localVertices { minP = simd_min(minP, v.position); maxP = simd_max(maxP, v.position) }
        let sub = MeshData(vertices: localVertices, indices: local, boundsMin: minP, boundsMax: maxP)
        let built = MeshletBuilder.build(sub, strategy: .cluster)

        let vertexBase = UInt32(result.meshletVertices.count)
        let triangleBase = UInt32(result.meshletTriangles.count)
        result.meshletVertices.append(contentsOf: built.meshletVertices.map { globalOf[Int($0)] })
        result.meshletTriangles.append(contentsOf: built.meshletTriangles)
        var indices: [Int] = []
        for var m in built.meshlets {
            m.vertexOffset += vertexBase
            m.triangleOffset += triangleBase
            m.materialIndex = material
            indices.append(result.meshlets.count)
            result.meshlets.append(m)
        }
        return indices
    }
}
