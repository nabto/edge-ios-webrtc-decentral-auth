import SwiftUI
import NabtoEdgeClientWebRTC

/// Wraps `EdgeMetalVideoView` (a UIKit Metal-backed video sink) for SwiftUI.
///
/// The view is owned externally (by `WebRtcSession`) so it survives across the
/// SwiftUI update cycle; tracks are attached to it once they arrive.
struct MetalVideoRepresentable: UIViewRepresentable {
    let view: EdgeMetalVideoView

    func makeUIView(context: Context) -> EdgeMetalVideoView { view }
    func updateUIView(_ uiView: EdgeMetalVideoView, context: Context) {}
}
