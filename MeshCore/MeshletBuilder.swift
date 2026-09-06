import Foundation
import simd

/// 메시렛으로 분할된 메시. GPU 버퍼로 그대로 올라간다.
public struct MeshletMesh: Sendable {
    public var vertices: [Vertex]
    public var meshlets: [Meshlet]
    /// 메시렛별 전역 정점 인덱스 (메시렛의 vertexOffset부터 vertexCount개)
    public var meshletVertices: [UInt32]
    /// 메시렛 로컬 인덱스 (0..<vertexCount), 삼각형당 3개
    public var meshletTriangles: [UInt8]
    /// 메시렛별 LOD 정보 (비어 있으면 LOD 없음 = 전부 레벨 0)
    public var lod: [MeshletLOD] = []

    public init(vertices: [Vertex], meshlets: [Meshlet], meshletVertices: [UInt32], meshletTriangles: [UInt8], lod: [MeshletLOD] = []) {
        self.vertices = vertices; self.meshlets = meshlets; self.meshletVertices = meshletVertices
        self.meshletTriangles = meshletTriangles; self.lod = lod
    }

    /// 전체 삼각형 수 (모든 LOD 레벨 합)
    public var triangleCount: Int { meshlets.reduce(0) { $0 + Int($1.triangleCount) } }
    /// 레벨 0 삼각형 수 (원본)
    public var level0TriangleCount: Int {
        guard !lod.isEmpty else { return triangleCount }
        return zip(meshlets, lod).reduce(0) { $0 + ($1.1.level == 0 ? Int($1.0.triangleCount) : 0) }
    }
    public var lodLevelCount: Int { lod.isEmpty ? 1 : Int((lod.map(\.level).max() ?? 0) + 1) }

    /// 메시렛 `i`의 삼각형들을 전역 정점 인덱스 삼중으로 돌려준다
    public func triangles(ofMeshlet i: Int) -> [UInt32] {
        let m = meshlets[i]
        var out = [UInt32](); out.reserveCapacity(Int(m.triangleCount) * 3)
        let base = Int(m.triangleOffset)
        for k in 0..<(Int(m.triangleCount) * 3) {
            out.append(meshletVertices[Int(m.vertexOffset) + Int(meshletTriangles[base + k])])
        }
        return out
    }
}

/// 삼각형을 메시렛으로 묶는다. 메시렛은 재질 하나만 갖는다.
///
/// - `.cluster` (기본): 인접 삼각형을 정점 재사용·노멀 정렬·거리 점수로 골라 키운다 (meshoptimizer buildMeshlets 방식의 단순화).
///   경계 구가 작고 콘이 좁아 컬링 효율이 가장 좋다.
/// - `.spatialScan`: Morton 코드로 정렬한 뒤 순서대로 자른다.
/// - `.scan`: 입력 순서대로 자른다 (순서 보존이 필요한 테스트용).
public enum MeshletBuilder {
    public enum Strategy: Sendable { case scan, spatialScan, cluster }

    public static func build(
        _ mesh: MeshData,
        maxVertices: Int = Int(MESHLET_MAX_VERTICES),
        maxTriangles: Int = Int(MESHLET_MAX_TRIANGLES),
        strategy: Strategy = .cluster
    ) -> MeshletMesh {
        precondition(maxVertices <= 256 && maxTriangles <= 512, "Metal 메시 셰이더 한계 초과")
        precondition(maxVertices >= 3 && maxTriangles >= 1)
        switch strategy {
        case .cluster: return buildClustered(mesh, maxVertices: maxVertices, maxTriangles: maxTriangles)
        case .spatialScan: return buildScan(mesh, maxVertices: maxVertices, maxTriangles: maxTriangles, spatialSort: true)
        case .scan: return buildScan(mesh, maxVertices: maxVertices, maxTriangles: maxTriangles, spatialSort: false)
        }
    }

    /// 호환용: spatialSort 불리언 → 전략
    public static func build(_ mesh: MeshData, maxVertices: Int = Int(MESHLET_MAX_VERTICES), maxTriangles: Int = Int(MESHLET_MAX_TRIANGLES), spatialSort: Bool) -> MeshletMesh {
        build(mesh, maxVertices: maxVertices, maxTriangles: maxTriangles, strategy: spatialSort ? .spatialScan : .scan)
    }

    // MARK: - 스캔 방식

    private static func buildScan(_ mesh: MeshData, maxVertices: Int, maxTriangles: Int, spatialSort: Bool) -> MeshletMesh {
        let vertices = mesh.vertices
        // 삼각형 순서: 재질 우선, 그 안에서 (선택) Morton 순. 메시렛은 재질 하나만 갖는다.
        let order = triangleOrder(mesh, spatialSort: spatialSort)
        var indices = [UInt32](); indices.reserveCapacity(mesh.indices.count)
        var triangleMaterial = [UInt32](); triangleMaterial.reserveCapacity(order.count)
        for t in order {
            indices.append(mesh.indices[t * 3]); indices.append(mesh.indices[t * 3 + 1]); indices.append(mesh.indices[t * 3 + 2])
            triangleMaterial.append(mesh.materialIndex(ofTriangle: t))
        }
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
                || Int(current.triangleCount) + 1 > maxTriangles
                || (current.triangleCount > 0 && current.materialIndex != triangleMaterial[t]) {
                flush(endTriangle: t)
            }
            if current.triangleCount == 0 { current.materialIndex = triangleMaterial[t] }

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

    // MARK: - 클러스터 방식

    private static func buildClustered(_ mesh: MeshData, maxVertices: Int, maxTriangles: Int) -> MeshletMesh {
        let vertices = mesh.vertices
        let indices = mesh.indices
        let triangleTotal = indices.count / 3
        var result = MeshletMesh(vertices: vertices, meshlets: [], meshletVertices: [], meshletTriangles: [])
        guard triangleTotal > 0, !vertices.isEmpty else { return result }
        result.meshlets.reserveCapacity(triangleTotal / (maxTriangles / 2) + 1)
        result.meshletVertices.reserveCapacity(triangleTotal * 3 / 2)
        result.meshletTriangles.reserveCapacity(triangleTotal * 3)

        // 삼각형 속성
        var centroids = [SIMD3<Float>](repeating: .zero, count: triangleTotal)
        var normals = [SIMD3<Float>](repeating: .zero, count: triangleTotal)
        var totalArea: Float = 0
        for t in 0..<triangleTotal {
            let a = vertices[Int(indices[t * 3])].position
            let b = vertices[Int(indices[t * 3 + 1])].position
            let c = vertices[Int(indices[t * 3 + 2])].position
            centroids[t] = (a + b + c) / 3
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            totalArea += len * 0.5
            normals[t] = len > 0 ? n / len : SIMD3(0, 1, 0)
        }
        // 메시렛 하나가 덮을 반지름 추정 (거리 점수 정규화용)
        let expectedRadius = max((totalArea / Float(triangleTotal) * Float(maxTriangles)).squareRoot() * 0.5, 1e-6)

        // 정점 → 삼각형 인접(CSR)
        var counts = [Int32](repeating: 0, count: vertices.count + 1)
        for i in indices { counts[Int(i) + 1] += 1 }
        for v in 0..<vertices.count { counts[v + 1] += counts[v] }
        var fill = counts
        var adjacency = [Int32](repeating: 0, count: indices.count)
        for t in 0..<triangleTotal {
            for k in 0..<3 {
                let v = Int(indices[t * 3 + k])
                adjacency[Int(fill[v])] = Int32(t); fill[v] += 1
            }
        }

        // 시드 후보 순서: 재질 우선 + Morton
        let seedOrder = triangleOrder(mesh, spatialSort: true)
        var seedCursor = 0
        var used = [Bool](repeating: false, count: triangleTotal)
        var localIndex = [Int16](repeating: -1, count: vertices.count)
        var inCandidates = [Bool](repeating: false, count: triangleTotal)
        var candidates: [Int32] = []
        candidates.reserveCapacity(1024)

        var current = Meshlet()
        var currentTriangles: [Int] = []          // 경계 계산용
        var centroidSum = SIMD3<Float>.zero
        var normalSum = SIMD3<Float>.zero
        var currentMaterial: UInt32 = 0
        /// 현재 메시렛을 만들며 추가된 후보의 시작 위치. 그 앞은 이전 메시렛들의 프런티어.
        var frontierStart = 0

        func flush() {
            guard current.triangleCount > 0 else { return }
            computeBounds(&current, vertices: vertices, indices: indices, triangles: currentTriangles)
            current.materialIndex = currentMaterial
            let start = Int(current.vertexOffset)
            for i in start..<(start + Int(current.vertexCount)) { localIndex[Int(result.meshletVertices[i])] = -1 }
            result.meshlets.append(current)
            current = Meshlet()
            current.vertexOffset = UInt32(result.meshletVertices.count)
            current.triangleOffset = UInt32(result.meshletTriangles.count)
            currentTriangles.removeAll(keepingCapacity: true)
            centroidSum = .zero
            normalSum = .zero
            // 이전 메시렛들의 프런티어는 버리고 방금 만든 메시렛의 프런티어만 남긴다 → 후보 목록이 O(N)으로 커지지 않는다
            let drop = min(frontierStart, candidates.count)
            for i in 0..<drop { inCandidates[Int(candidates[i])] = false }
            candidates.removeFirst(drop)
            frontierStart = candidates.count
        }

        func extraVertices(_ t: Int) -> Int {
            let a = indices[t * 3], b = indices[t * 3 + 1], c = indices[t * 3 + 2]
            return (localIndex[Int(a)] < 0 ? 1 : 0)
                + (localIndex[Int(b)] < 0 && b != a ? 1 : 0)
                + (localIndex[Int(c)] < 0 && c != a && c != b ? 1 : 0)
        }

        func add(_ t: Int) {
            used[t] = true
            if current.triangleCount == 0 { currentMaterial = mesh.materialIndex(ofTriangle: t) }
            for k in 0..<3 {
                let v = indices[t * 3 + k]
                if localIndex[Int(v)] < 0 {
                    localIndex[Int(v)] = Int16(current.vertexCount)
                    result.meshletVertices.append(v)
                    current.vertexCount += 1
                    // 새 정점의 인접 삼각형을 후보에 추가
                    for j in Int(counts[Int(v)])..<Int(counts[Int(v) + 1]) {
                        let u = Int(adjacency[j])
                        if !used[u] && !inCandidates[u] { inCandidates[u] = true; candidates.append(Int32(u)) }
                    }
                }
                result.meshletTriangles.append(UInt8(localIndex[Int(v)]))
            }
            current.triangleCount += 1
            currentTriangles.append(t)
            centroidSum += centroids[t]
            normalSum += normals[t]
        }

        /// 후보 중 최고점 (extra 적은 것 우선, 같으면 점수 낮은 것). 사용된 후보는 정리.
        func pickBest() -> Int? {
            var best = -1, bestExtra = Int.max
            var bestScore = Float.greatestFiniteMagnitude
            let count = Float(max(current.triangleCount, 1))
            let center = centroidSum / count
            let axisLen = simd_length(normalSum)
            let axis = axisLen > 0 ? normalSum / axisLen : SIMD3<Float>.zero
            // 사용된/다른 재질 후보를 순서를 유지하며 제거 (frontierStart가 의미를 잃지 않도록)
            var write = 0
            for read in 0..<candidates.count {
                let t = Int(candidates[read])
                if used[t] || (current.triangleCount > 0 && mesh.materialIndex(ofTriangle: t) != currentMaterial) {
                    inCandidates[t] = false
                    if read < frontierStart { frontierStart -= 1 }
                    continue
                }
                candidates[write] = candidates[read]
                write += 1
            }
            candidates.removeLast(candidates.count - write)
            frontierStart = min(frontierStart, candidates.count)
            var i = 0
            while i < candidates.count {
                let t = Int(candidates[i])
                let extra = extraVertices(t)
                let distance = simd_distance(centroids[t], center)
                let spread = simd_dot(normals[t], axis)          // -1…1, 클수록 콘이 좁게 유지됨
                let cone = max(1 - spread * 0.5, 1e-3)            // cone_weight 0.5
                let score = (1 + distance / expectedRadius * 0.5) * cone
                if extra < bestExtra || (extra == bestExtra && score < bestScore) {
                    best = t; bestExtra = extra; bestScore = score
                }
                i += 1
            }
            return best >= 0 ? best : nil
        }

        /// Morton 순서상 다음 미사용 삼각형들(최대 64개) 중 `center`에 가장 가까운 것. center가 nil이면 첫 번째.
        func nextSeed(near center: SIMD3<Float>?) -> Int? {
            while seedCursor < seedOrder.count, used[seedOrder[seedCursor]] { seedCursor += 1 }
            guard seedCursor < seedOrder.count else { return nil }
            guard let center else { return seedOrder[seedCursor] }
            var best = -1
            var bestDistance = Float.greatestFiniteMagnitude
            var scanned = 0
            var i = seedCursor
            while i < seedOrder.count && scanned < 64 {
                let t = seedOrder[i]; i += 1
                if used[t] { continue }
                scanned += 1
                let d = simd_distance_squared(centroids[t], center)
                if d < bestDistance { bestDistance = d; best = t }
            }
            return best >= 0 ? best : nil
        }

        while true {
            var next = pickBest()
            if next == nil {
                // 인접 후보가 없다(섬 경계). 가까운 미사용 삼각형이면 같은 메시렛에 이어 담고, 멀면 메시렛을 닫는다.
                for c in candidates { inCandidates[Int(c)] = false }
                candidates.removeAll(keepingCapacity: true)
                frontierStart = 0
                let center: SIMD3<Float>? = current.triangleCount > 0 ? centroidSum / Float(current.triangleCount) : nil
                guard let seed = nextSeed(near: center) else { break }
                if let center, simd_distance(centroids[seed], center) > expectedRadius * 1.5 {
                    flush()
                }
                next = seed
            }
            let t = next!
            if current.triangleCount > 0 {
                let fits = Int(current.vertexCount) + extraVertices(t) <= maxVertices
                    && Int(current.triangleCount) + 1 <= maxTriangles
                    && mesh.materialIndex(ofTriangle: t) == currentMaterial
                if !fits { flush() }
            }
            inCandidates[t] = false
            add(t)
        }
        flush()
        return result
    }

    /// 삼각형 처리 순서. 재질 인덱스 우선, 같은 재질 안에서는 Morton 코드(30비트) 순 또는 원래 순서.
    static func triangleOrder(_ mesh: MeshData, spatialSort: Bool) -> [Int] {
        let triangleTotal = mesh.indices.count / 3
        guard triangleTotal > 0 else { return [] }
        let extent = mesh.boundsMax - mesh.boundsMin
        let scale = SIMD3<Float>(
            extent.x > 0 ? 1023 / extent.x : 0,
            extent.y > 0 ? 1023 / extent.y : 0,
            extent.z > 0 ? 1023 / extent.z : 0
        )
        var keys = [(key: UInt64, triangle: Int)]()
        keys.reserveCapacity(triangleTotal)
        for t in 0..<triangleTotal {
            var spatial: UInt64 = UInt64(t)   // 정렬 안 하면 원래 순서 유지
            if spatialSort {
                let a = mesh.vertices[Int(mesh.indices[t * 3])].position
                let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])].position
                let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])].position
                let q = ((a + b + c) / 3 - mesh.boundsMin) * scale
                let x = UInt32(min(max(q.x, 0), 1023)), y = UInt32(min(max(q.y, 0), 1023)), z = UInt32(min(max(q.z, 0), 1023))
                spatial = UInt64(morton(x) | morton(y) << 1 | morton(z) << 2)
            }
            keys.append((UInt64(mesh.materialIndex(ofTriangle: t)) << 32 | spatial, t))
        }
        keys.sort { $0.key < $1.key }
        return keys.map(\.triangle)
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
        computeBounds(&meshlet, vertices: vertices, indices: indices, triangles: Array(triangleRange))
    }

    private static func computeBounds(_ meshlet: inout Meshlet, vertices: [Vertex], indices: [UInt32], triangles triangleRange: [Int]) {
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
