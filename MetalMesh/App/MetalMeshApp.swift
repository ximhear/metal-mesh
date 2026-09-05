import SwiftUI

@main
struct MetalMeshApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
    }
}
