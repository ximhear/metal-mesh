import MeshCore
import simd

/// 타깃을 중심으로 회전·줌·팬하는 카메라. 메인 스레드에서만 접근한다.
final class OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 3
    var yaw: Float = 0.6        // 라디안, y축 회전
    var pitch: Float = 0.35     // 라디안, 위아래
    var fovY: Float = .pi / 4
    var aspect: Float = 1

    private(set) var sceneRadius: Float = 1
    private var minDistance: Float = 0.05
    private var maxDistance: Float = 100

    /// 경계 구가 화면에 들어오도록 카메라를 배치한다.
    func frame(center: SIMD3<Float>, radius: Float) {
        let r = max(radius, 1e-4)
        target = center
        sceneRadius = r
        // r은 AABB 반대각선이라 실제 형상보다 크다. 0.9배로 여백을 줄인다.
        distance = r / sin(fovY * 0.5) * 0.9
        minDistance = r * 0.05
        maxDistance = r * 25
    }

    var position: SIMD3<Float> {
        let cp = cos(pitch)
        let dir = SIMD3(cp * sin(yaw), sin(pitch), cp * cos(yaw))
        return target + dir * distance
    }

    var viewMatrix: float4x4 {
        Math.lookAt(eye: position, target: target, up: SIMD3(0, 1, 0))
    }

    var projectionMatrix: float4x4 {
        let near = max(distance - sceneRadius * 1.5, sceneRadius * 0.005)
        let far = distance + sceneRadius * 2.5
        return Math.perspective(fovY: fovY, aspect: max(aspect, 0.01), near: near, far: far)
    }

    // MARK: - 조작

    func rotate(deltaYaw: Float, deltaPitch: Float) {
        yaw += deltaYaw
        pitch = min(max(pitch + deltaPitch, -1.53), 1.53)
    }

    /// factor > 1 이면 가까워진다
    func zoom(factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        distance = min(max(distance / factor, minDistance), maxDistance)
    }

    /// 화면 픽셀 이동량을 카메라 우/상 방향 이동으로 바꾼다
    func pan(deltaX: Float, deltaY: Float, viewportHeight: Float) {
        guard viewportHeight > 0 else { return }
        let worldPerPixel = 2 * distance * tan(fovY * 0.5) / viewportHeight
        let view = viewMatrix
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        target += (-right * deltaX + up * deltaY) * worldPerPixel
    }
}
