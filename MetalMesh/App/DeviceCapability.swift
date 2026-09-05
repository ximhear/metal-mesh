import Metal

/// 현재 기기의 Metal 지원 여부. 앱 시작 시 한 번 계산한다.
struct DeviceCapability: Sendable {
    let deviceName: String
    let hasMetal3: Bool
    let hasAppleSiliconGPU: Bool
    let supportsMeshShaders: Bool

    static let current = DeviceCapability(device: MTLCreateSystemDefaultDevice())

    init(device: MTLDevice?) {
        guard let device else {
            deviceName = "없음"
            hasMetal3 = false
            hasAppleSiliconGPU = false
            supportsMeshShaders = false
            return
        }
        deviceName = device.name
        hasMetal3 = device.supportsFamily(.metal3)
        hasAppleSiliconGPU = device.supportsFamily(.apple7)
        // 메시 셰이더(object/mesh 스테이지)는 Metal 3 + Apple7 이상(A14/M1+)에서 지원된다고 가정한다.
        // Intel Mac(mac2)도 Metal 3면 지원 목록에 있으나 이 앱은 Apple 실리콘만 검증한다.
        // 정확한 최소 사양은 Apple Metal Feature Set Tables로 재확인할 것.
        supportsMeshShaders = hasMetal3 && (hasAppleSiliconGPU || device.supportsFamily(.mac2))
    }

    var summary: String {
        """
        GPU: \(deviceName)
        Metal 3: \(hasMetal3 ? "지원" : "미지원")
        Apple7 이상: \(hasAppleSiliconGPU ? "예" : "아니오")
        메시 셰이더: \(supportsMeshShaders ? "지원" : "미지원")
        """
    }
}
