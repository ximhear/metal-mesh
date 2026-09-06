import Foundation
import simd

/// 쿼드릭 오차(Garland–Heckbert) 기반 하프에지 붕괴 단순화.
/// 정점을 새로 만들지 않고 기존 정점으로만 붕괴하므로(UV·노멀 유지) 출력 삼각형은 입력 정점 인덱스를 그대로 쓴다.
/// 잠긴 정점(그룹 경계·메시 외곽)은 이동/제거되지 않는다 → 이웃 그룹과 크랙이 생기지 않는다.
public enum MeshSimplifier {
    public struct Result {
        public var triangles: [UInt32]   // 전역 정점 인덱스, 3개씩
        /// 붕괴로 생긴 최대 기하 오차 (모델 단위, 쿼드릭 거리의 제곱근)
        public var error: Float
    }

    /// - Parameters:
    ///   - triangles: 전역 정점 인덱스 삼중 목록
    ///   - locked: 전역 정점 인덱스가 잠겨 있으면 true
    ///   - targetTriangleCount: 이 수 이하가 되면 멈춘다
    public static func simplify(vertices: [Vertex], triangles: [UInt32], locked: (UInt32) -> Bool, targetTriangleCount: Int) -> Result {
        let triCount = triangles.count / 3
        guard triCount > 0 else { return Result(triangles: [], error: 0) }

        // 전역 → 로컬 압축
        var globalOf: [UInt32] = []
        var localOf: [UInt32: Int32] = [:]
        var tris = [Int32](repeating: 0, count: triCount * 3)
        for i in 0..<(triCount * 3) {
            let g = triangles[i]
            if let l = localOf[g] { tris[i] = l } else {
                let l = Int32(globalOf.count); globalOf.append(g); localOf[g] = l; tris[i] = l
            }
        }
        let n = globalOf.count
        var positions = [SIMD3<Float>](); positions.reserveCapacity(n)
        var isLocked = [Bool](); isLocked.reserveCapacity(n)
        for g in globalOf { positions.append(vertices[Int(g)].position); isLocked.append(locked(g)) }

        // 정점 쿼드릭 (면적 가중 평면)
        var quadrics = [Quadric](repeating: Quadric(), count: n)
        var alive = [Bool](repeating: true, count: triCount)
        var vertexTris = [[Int32]](repeating: [], count: n)
        for t in 0..<triCount {
            let a = Int(tris[t * 3]), b = Int(tris[t * 3 + 1]), c = Int(tris[t * 3 + 2])
            if a == b || b == c || a == c { alive[t] = false; continue }
            let q = Quadric(plane: positions[a], positions[b], positions[c])
            quadrics[a] += q; quadrics[b] += q; quadrics[c] += q
            vertexTris[a].append(Int32(t)); vertexTris[b].append(Int32(t)); vertexTris[c].append(Int32(t))
        }
        var remaining = alive.filter { $0 }.count

        // 에지 힙 (게으른 무효화: 정점 버전이 바뀌면 항목 폐기)
        var version = [UInt32](repeating: 0, count: n)
        var heap = Heap()
        var remap = [Int32](0..<Int32(n))
        func find(_ v: Int32) -> Int32 { var v = v; while remap[Int(v)] != v { v = remap[Int(v)] }; return v }

        func push(_ a: Int32, _ b: Int32) {
            let a = find(a), b = find(b)
            guard a != b else { return }
            let la = isLocked[Int(a)], lb = isLocked[Int(b)]
            if la && lb { return }
            // 붕괴 방향: 자유 → 잠김. 둘 다 자유면 비용이 낮은 쪽
            let q = quadrics[Int(a)] + quadrics[Int(b)]
            var from = a, to = b, cost = q.evaluate(positions[Int(b)])
            if la { from = b; to = a; cost = q.evaluate(positions[Int(a)]) }
            else if !lb {
                let costA = q.evaluate(positions[Int(a)])
                if costA < cost { from = b; to = a; cost = costA }
            }
            heap.push(Heap.Item(cost: cost, from: from, to: to, vFrom: version[Int(from)], vTo: version[Int(to)]))
        }
        var seen = Set<UInt64>()
        for t in 0..<triCount where alive[t] {
            for k in 0..<3 {
                let a = tris[t * 3 + k], b = tris[t * 3 + (k + 1) % 3]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if seen.insert(key).inserted { push(a, b) }
            }
        }

        var maxError: Float = 0
        while remaining > targetTriangleCount, let item = heap.pop() {
            let from = item.from, to = item.to
            guard remap[Int(from)] == from, remap[Int(to)] == to,
                  version[Int(from)] == item.vFrom, version[Int(to)] == item.vTo else { continue }
            // 링크 조건: from·to 공통 이웃은 (from,to) 에지를 공유하는 삼각형의 맞은편 정점뿐이어야 한다
            // (아니면 붕괴 후 비다양체/구멍이 생긴다)
            var sharedTriangles = 0
            var opposite = Set<Int32>()
            var neighborsFrom = Set<Int32>()
            for tIdx in vertexTris[Int(from)] where alive[Int(tIdx)] {
                let t = Int(tIdx)
                let a = find(tris[t * 3]), b = find(tris[t * 3 + 1]), c = find(tris[t * 3 + 2])
                let vs = [a, b, c]
                if vs.contains(to) {
                    sharedTriangles += 1
                    for v in vs where v != from && v != to { opposite.insert(v) }
                }
                for v in vs where v != from { neighborsFrom.insert(v) }
            }
            var neighborsTo = Set<Int32>()
            for tIdx in vertexTris[Int(to)] where alive[Int(tIdx)] {
                let t = Int(tIdx)
                for k in 0..<3 { let v = find(tris[t * 3 + k]); if v != to { neighborsTo.insert(v) } }
            }
            let common = neighborsFrom.intersection(neighborsTo)
            if sharedTriangles == 0 || common != opposite { continue }
            // 잠긴 정점 보호: 사라지는 삼각형(from·to를 모두 포함) 때문에 잠긴 맞은편 정점의 삼각형이 0개가 되면 거부
            var protectedVertexStarves = false
            for v in opposite where isLocked[Int(v)] {
                var aliveCount = 0, dying = 0
                for tIdx in vertexTris[Int(v)] where alive[Int(tIdx)] {
                    aliveCount += 1
                    let t = Int(tIdx)
                    let vs = [find(tris[t * 3]), find(tris[t * 3 + 1]), find(tris[t * 3 + 2])]
                    if vs.contains(from) && vs.contains(to) { dying += 1 }
                }
                if aliveCount - dying < 1 { protectedVertexStarves = true; break }
            }
            // 잠긴 to 정점: 붕괴 후 남는 삼각형 = (기존 − 공유) + (from에서 넘어오는 비공유 삼각형). 0이면 거부
            if !protectedVertexStarves && isLocked[Int(to)] {
                var aliveTo = 0
                for tIdx in vertexTris[Int(to)] where alive[Int(tIdx)] { aliveTo += 1 }
                var incoming = 0
                for tIdx in vertexTris[Int(from)] where alive[Int(tIdx)] {
                    let t = Int(tIdx)
                    let vs = [find(tris[t * 3]), find(tris[t * 3 + 1]), find(tris[t * 3 + 2])]
                    if !vs.contains(to) { incoming += 1 }
                }
                if aliveTo - sharedTriangles + incoming < 1 { protectedVertexStarves = true }
            }
            if protectedVertexStarves { continue }

            // 뒤집힘 검사: from을 to로 옮겼을 때 살아남는 삼각형의 노멀이 반전되면 거부
            var flips = false
            for tIdx in vertexTris[Int(from)] {
                let t = Int(tIdx)
                guard alive[t] else { continue }
                let i = [Int(find(tris[t * 3])), Int(find(tris[t * 3 + 1])), Int(find(tris[t * 3 + 2]))]
                if i.contains(Int(to)) { continue }   // 사라질 삼각형
                let before = simd_cross(positions[i[1]] - positions[i[0]], positions[i[2]] - positions[i[0]])
                let j = i.map { $0 == Int(from) ? Int(to) : $0 }
                let after = simd_cross(positions[j[1]] - positions[j[0]], positions[j[2]] - positions[j[0]])
                if simd_dot(before, after) <= 0 { flips = true; break }
            }
            if flips { continue }

            // 붕괴 수행. 오차는 합산 쿼드릭의 정규화 거리(모델 단위)
            let merged = quadrics[Int(to)] + quadrics[Int(from)]
            maxError = max(maxError, merged.distance(positions[Int(to)]))
            remap[Int(from)] = to
            quadrics[Int(to)] = merged
            version[Int(to)] += 1
            var moved: [Int32] = []
            for tIdx in vertexTris[Int(from)] {
                let t = Int(tIdx)
                guard alive[t] else { continue }
                let a = find(tris[t * 3]), b = find(tris[t * 3 + 1]), c = find(tris[t * 3 + 2])
                if a == b || b == c || a == c { alive[t] = false; remaining -= 1 } else { moved.append(tIdx) }
            }
            vertexTris[Int(to)].append(contentsOf: moved)
            vertexTris[Int(from)].removeAll()
            // to 주변 에지 비용 갱신
            var neighbors = Set<Int32>()
            for tIdx in vertexTris[Int(to)] where alive[Int(tIdx)] {
                let t = Int(tIdx)
                for k in 0..<3 { let v = find(tris[t * 3 + k]); if v != to { neighbors.insert(v) } }
            }
            for v in neighbors { push(to, v) }
        }

        var out = [UInt32](); out.reserveCapacity(remaining * 3)
        for t in 0..<triCount where alive[t] {
            let a = find(tris[t * 3]), b = find(tris[t * 3 + 1]), c = find(tris[t * 3 + 2])
            guard a != b, b != c, a != c else { continue }
            out.append(globalOf[Int(a)]); out.append(globalOf[Int(b)]); out.append(globalOf[Int(c)])
        }
        return Result(triangles: out, error: maxError)
    }

    // MARK: - 내부

    /// 대칭 4×4 쿼드릭 (10개 계수)
    struct Quadric {
        var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0
        var e: Float = 0, f: Float = 0, g: Float = 0
        var h: Float = 0, i: Float = 0
        var j: Float = 0
        /// 누적 면적 (오차를 모델 단위 RMS 거리로 정규화할 때 사용)
        var w: Float = 0

        init() {}
        init(plane p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>) {
            let cross = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(cross)
            guard len > 1e-20 else { return }
            let n = cross / len
            let area = len * 0.5
            let dd = -simd_dot(n, p0)
            a = n.x * n.x * area; b = n.x * n.y * area; c = n.x * n.z * area; d = n.x * dd * area
            e = n.y * n.y * area; f = n.y * n.z * area; g = n.y * dd * area
            h = n.z * n.z * area; i = n.z * dd * area
            j = dd * dd * area
            w = area
        }
        static func += (l: inout Quadric, r: Quadric) {
            l.a += r.a; l.b += r.b; l.c += r.c; l.d += r.d; l.e += r.e; l.f += r.f; l.g += r.g; l.h += r.h; l.i += r.i; l.j += r.j
            l.w += r.w
        }
        static func + (l: Quadric, r: Quadric) -> Quadric { var q = l; q += r; return q }
        func evaluate(_ p: SIMD3<Float>) -> Float {
            a * p.x * p.x + 2 * b * p.x * p.y + 2 * c * p.x * p.z + 2 * d * p.x
                + e * p.y * p.y + 2 * f * p.y * p.z + 2 * g * p.y
                + h * p.z * p.z + 2 * i * p.z + j
        }
        /// 면적으로 정규화한 평면 거리 RMS (모델 단위)
        func distance(_ p: SIMD3<Float>) -> Float {
            w > 1e-20 ? (max(evaluate(p), 0) / w).squareRoot() : 0
        }
    }

    struct Heap {
        struct Item { var cost: Float; var from: Int32; var to: Int32; var vFrom: UInt32; var vTo: UInt32 }
        private var items: [Item] = []
        var isEmpty: Bool { items.isEmpty }
        mutating func push(_ item: Item) {
            items.append(item)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if items[parent].cost <= items[i].cost { break }
                items.swapAt(parent, i); i = parent
            }
        }
        mutating func pop() -> Item? {
            guard !items.isEmpty else { return nil }
            let top = items[0]
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count && items[l].cost < items[m].cost { m = l }
                    if r < items.count && items[r].cost < items[m].cost { m = r }
                    if m == i { break }
                    items.swapAt(m, i); i = m
                }
            }
            return top
        }
    }
}
