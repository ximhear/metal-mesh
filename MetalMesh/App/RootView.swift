import SwiftUI

/// 앱 진입점. 기기가 메시 셰이더를 지원하면 라이브러리 화면, 아니면 안내 화면.
struct RootView: View {
    private let capability = DeviceCapability.current

    var body: some View {
        if capability.supportsMeshShaders {
            NavigationStack {
                LibraryPlaceholderView()
            }
        } else {
            UnsupportedDeviceView(capability: capability)
        }
    }
}

/// Phase 1에서 ModelListView로 교체된다.
private struct LibraryPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "모델이 없습니다",
            systemImage: "cube.transparent",
            description: Text("Phase 1에서 모델 추가 기능이 들어옵니다.")
        )
        .navigationTitle("Models")
    }
}
