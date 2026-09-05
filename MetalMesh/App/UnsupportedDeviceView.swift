import SwiftUI

struct UnsupportedDeviceView: View {
    let capability: DeviceCapability

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("이 기기는 Metal 3 메시 셰이더를 지원하지 않습니다")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("iPhone/iPad는 A14 이상, Mac은 Apple 실리콘이 필요합니다.\niOS 시뮬레이터는 메시 셰이더를 지원하지 않습니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(capability.summary)
                .font(.caption.monospaced())
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }
}
