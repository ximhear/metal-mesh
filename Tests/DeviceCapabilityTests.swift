import Testing
import Metal
@testable import MetalMesh

struct DeviceCapabilityTests {
    @Test func nilDeviceIsUnsupported() {
        let cap = DeviceCapability(device: nil)
        #expect(cap.supportsMeshShaders == false)
        #expect(cap.hasMetal3 == false)
    }

    @Test func currentDeviceReportsConsistentFlags() {
        let cap = DeviceCapability.current
        // 메시 셰이더 지원이면 Metal 3는 반드시 참이어야 한다.
        if cap.supportsMeshShaders { #expect(cap.hasMetal3) }
    }
}
