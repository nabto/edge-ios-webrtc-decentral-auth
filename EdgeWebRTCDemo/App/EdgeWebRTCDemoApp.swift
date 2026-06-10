import SwiftUI
import OSLog
import NabtoEdgeClientWebRTC

private let lifecycleLog = Logger(subsystem: "com.nabto.EdgeWebRTCDemo", category: "Lifecycle")

@main
struct EdgeWebRTCDemoApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        EdgeWebrtc.setLogLevel(.verbose)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                lifecycleLog.info("scenePhase=background, closing all Nabto connections")
                Task { await EdgeConnectionManager.shared.closeAllConnections() }
            case .active:
                lifecycleLog.info("scenePhase=active")
            case .inactive:
                lifecycleLog.info("scenePhase=inactive")
            @unknown default:
                break
            }
        }
    }
}

@Observable
@MainActor
final class AppModel {
    let bookmarks = BookmarkStore()
    let toaster = Toaster()
}
