import SwiftUI
import NabtoEdgeClientWebRTC

@main
struct EdgeWebRTCDemoApp: App {
    @State private var appModel = AppModel()

    init() {
        EdgeWebrtc.setLogLevel(.info)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
    }
}

@Observable
@MainActor
final class AppModel {
    let bookmarks = BookmarkStore()
    let toaster = Toaster()
}
