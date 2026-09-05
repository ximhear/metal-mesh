import simd

public enum Math {
    /// 오른손 좌표계, Metal 깊이 범위 [0, 1] 원근 투영
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        )
    }

    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(target - eye)          // 앞 (-z)
        let s = simd_normalize(simd_cross(f, up))     // 오른쪽
        let u = simd_cross(s, f)                      // 위
        return float4x4(
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        )
    }

    public static func upperLeft3x3(_ m: float4x4) -> float3x3 {
        float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    /// Gribb–Hartmann: 클립 행렬에서 프러스텀 평면 6개 추출 (안쪽 양수, 정규화).
    /// Metal 클립 z ∈ [0, w] 기준. 순서: left, right, bottom, top, near, far
    public static func frustumPlanes(from m: float4x4) -> [SIMD4<Float>] {
        func row(_ i: Int) -> SIMD4<Float> {
            SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i])
        }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        let planes = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
        return planes.map { p in
            let len = simd_length(SIMD3(p.x, p.y, p.z))
            return len > 0 ? p / len : p
        }
    }
}
