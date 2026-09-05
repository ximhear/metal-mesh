import SwiftUI

/// 앱 진입점. 기기가 메시 셰이더를 지원하면 라이브러리 화면, 아니면 안내 화면.
struct RootView: View {
    private let capability = DeviceCapability.current
    @State private var library: ModelLibrary
    @State private var thumbnails: ThumbnailStore

    init() {
        let library = ModelLibrary()
        _library = State(initialValue: library)
        _thumbnails = State(initialValue: ThumbnailStore(library: library))
    }

    var body: some View {
        if capability.supportsMeshShaders {
            NavigationStack {
                ModelListView()
            }
            .environment(library)
            .environment(thumbnails)
            .task { library.load() }
        } else {
            UnsupportedDeviceView(capability: capability)
        }
    }
}
