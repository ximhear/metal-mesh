import MeshCore
import simd

/// 타깃을 중심으로 회전·줌·팬하는 카메라. 메인 스레드에서만 접근한다.
///
/// 방향은 쿼터니언으로 저장하고, 드래그는 트랙볼 방식(드래그 벡터에 수직인 축으로 회전)이라 짐벌 락이 없다.
/// `yaw`/`pitch`는 초기 자세를 지정하는 편의 속성이며, 드래그 회전 후에는 실제 방향과 무관하다.
final class OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 3
    var fovY: Float = .pi / 4
    var aspect: Float = 1

    /// 카메라 방향. 단위 쿼터니언. `orientation.act([0,0,1])`이 타깃→카메라 방향.
    private(set) var orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))

    /// y축 회전(라디안). 설정하면 pitch와 함께 orientation을 다시 만든다.
    var yaw: Float = 0.6 { didSet { rebuildOrientation() } }
    /// 위아래 각도(라디안). 양수면 위에서 내려다본다.
    var pitch: Float = 0.35 { didSet { rebuildOrientation() } }

    private(set) var sceneRadius: Float = 1
    private var minDistance: Float = 0.05
    private var maxDistance: Float = 100

    init() { rebuildOrientation() }

    private func rebuildOrientation() {
        // (0,0,1)을 pitch만큼 들어 올린 뒤 yaw로 돈다 → (cos p sin y, sin p, cos p cos y)
        let pitchRotation = simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
        let yawRotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        orientation = simd_normalize(yawRotation * pitchRotation)
    }

    /// 경계 구가 화면에 들어오도록 카메라를 배치한다. 방향은 유지한다.
    func frame(center: SIMD3<Float>, radius: Float) {
        let r = max(radius, 1e-4)
        target = center
        sceneRadius = r
        // r은 AABB 반대각선이라 실제 형상보다 크다. 0.9배로 여백을 줄인다.
        distance = r / sin(fovY * 0.5) * 0.9
        minDistance = r * 0.05
        maxDistance = r * 25
    }

    var right: SIMD3<Float> { orientation.act(SIMD3(1, 0, 0)) }
    var up: SIMD3<Float> { orientation.act(SIMD3(0, 1, 0)) }
    /// 타깃 → 카메라 단위 벡터
    var backward: SIMD3<Float> { orientation.act(SIMD3(0, 0, 1)) }

    var position: SIMD3<Float> { target + backward * distance }

    var viewMatrix: float4x4 {
        Math.lookAt(eye: position, target: target, up: up)
    }

    var projectionMatrix: float4x4 {
        let near = max(distance - sceneRadius * 1.5, sceneRadius * 0.005)
        let far = distance + sceneRadius * 2.5
        return Math.perspective(fovY: fovY, aspect: max(aspect, 0.01), near: near, far: far)
    }

    // MARK: - 조작

    /// 트랙볼 회전. `deltaYaw`는 화면 가로 드래그, `deltaPitch`는 세로 드래그에 대응하는 각도(라디안).
    /// 두 성분을 합친 한 번의 회전이라 드래그한 방향으로 그대로 돈다.
    func rotate(deltaYaw: Float, deltaPitch: Float) {
        let angle = (deltaYaw * deltaYaw + deltaPitch * deltaPitch).squareRoot()
        guard angle > 1e-6, angle.isFinite else { return }
        // yaw는 카메라 up 축 회전, pitch 증가(위에서 보기)는 right 축 기준 -각도 회전
        let axis = simd_normalize(up * deltaYaw - right * deltaPitch)
        orientation = simd_normalize(simd_quatf(angle: angle, axis: axis) * orientation)
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
        target += (-right * deltaX + up * deltaY) * worldPerPixel
    }
}
