import Foundation
import simd

/// 로더 공통 후처리: 정점 용접, 노멀 생성
public enum MeshPostProcess {
    private struct Key: Hashable {
        let px: UInt32, py: UInt32, pz: UInt32
        let u: UInt32, v: UInt32
        let nx: UInt32, ny: UInt32, nz: UInt32
    }

    /// 속성이 완전히 같은 정점을 하나로 합치고 인덱스를 다시 매핑한다.
    /// Model I/O가 면마다 쪼갠 정점을 되돌려 메시렛의 정점 재사용률을 높인다.
    /// - Parameter includeNormals: false면 노멀을 무시하고 위치+UV만으로 합친다(노멀을 새로 계산할 때).
    public static func weld(_ mesh: inout MeshData, includeNormals: Bool) {
        guard !mesh.vertices.isEmpty else { return }
        var remap = [UInt32](repeating: 0, count: mesh.vertices.count)
        var lookup = [Key: UInt32](minimumCapacity: mesh.vertices.count)
        var welded: [Vertex] = []
        welded.reserveCapacity(mesh.vertices.count / 2)
        for (i, v) in mesh.vertices.enumerated() {
            let key = Key(px: v.position.x.bitPattern, py: v.position.y.bitPattern, pz: v.position.z.bitPattern,
                          u: v.uv.x.bitPattern, v: v.uv.y.bitPattern,
                          nx: includeNormals ? v.normal.x.bitPattern : 0,
                          ny: includeNormals ? v.normal.y.bitPattern : 0,
                          nz: includeNormals ? v.normal.z.bitPattern : 0)
            if let existing = lookup[key] {
                remap[i] = existing
            } else {
                let index = UInt32(welded.count)
                lookup[key] = index
                remap[i] = index
                welded.append(v)
            }
        }
        guard welded.count < mesh.vertices.count else { return }
        mesh.vertices = welded
        for i in mesh.indices.indices { mesh.indices[i] = remap[Int(mesh.indices[i])] }
    }

    /// 면적 가중 스무스 노멀. 퇴화 삼각형은 무시한다.
    public static func computeSmoothNormals(_ mesh: inout MeshData) {
        var acc = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            let n = simd_cross(mesh.vertices[b].position - mesh.vertices[a].position,
                               mesh.vertices[c].position - mesh.vertices[a].position)
            acc[a] += n; acc[b] += n; acc[c] += n
        }
        for i in mesh.vertices.indices {
            let n = acc[i]
            mesh.vertices[i].normal = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
        }
    }

    /// UV 기울기로 정점 탄젠트(+손잡이)를 계산한다 (Lengyel). UV가 전부 0이면 탄젠트를 0으로 둔다.
    public static func computeTangents(_ mesh: inout MeshData) {
        let n = mesh.vertices.count
        guard n > 0, mesh.vertices.contains(where: { $0.uv != .zero }) else {
            for i in mesh.vertices.indices { mesh.vertices[i].tangent = .zero }
            return
        }
        var tan1 = [SIMD3<Float>](repeating: .zero, count: n)
        var tan2 = [SIMD3<Float>](repeating: .zero, count: n)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let i0 = Int(mesh.indices[t]), i1 = Int(mesh.indices[t + 1]), i2 = Int(mesh.indices[t + 2])
            let v0 = mesh.vertices[i0], v1 = mesh.vertices[i1], v2 = mesh.vertices[i2]
            let e1 = v1.position - v0.position, e2 = v2.position - v0.position
            let d1 = v1.uv - v0.uv, d2 = v2.uv - v0.uv
            let det = d1.x * d2.y - d2.x * d1.y
            guard abs(det) > 1e-12 else { continue }
            let r = 1 / det
            let sdir = (e1 * d2.y - e2 * d1.y) * r
            let tdir = (e2 * d1.x - e1 * d2.x) * r
            tan1[i0] += sdir; tan1[i1] += sdir; tan1[i2] += sdir
            tan2[i0] += tdir; tan2[i1] += tdir; tan2[i2] += tdir
        }
        for i in 0..<n {
            let nrm = mesh.vertices[i].normal
            let t = tan1[i]
            // Gram-Schmidt 직교화
            let ortho = t - nrm * simd_dot(nrm, t)
            guard simd_length(ortho) > 1e-8 else { mesh.vertices[i].tangent = .zero; continue }
            let tangent = simd_normalize(ortho)
            let handedness: Float = simd_dot(simd_cross(nrm, tangent), tan2[i]) < 0 ? -1 : 1
            mesh.vertices[i].tangent = SIMD4(tangent, handedness)
        }
    }
}
