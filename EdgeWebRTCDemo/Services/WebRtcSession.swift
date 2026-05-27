import Foundation
import NabtoEdgeClient
import NabtoEdgeClientWebRTC

enum WebRtcSessionError: LocalizedError {
    case tracksRequestFailed(status: UInt16)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .tracksRequestFailed(let status):
            return "Device rejected /webrtc/tracks (CoAP status \(status))."
        case .underlying(let error):
            return "WebRTC session error: \(error)"
        }
    }
}

/// Owns the `EdgePeerConnection` and remote tracks for a single device view.
///
/// Decentralized-IAM flavor: no `/webrtc/oauth` handshake — the Nabto connection
/// is already authenticated by the paired user's keypair, and the device-side
/// WebRTC handler uses the IAM role mapping to authorize media access.
@MainActor
final class WebRtcSession {
    enum State: Equatable {
        case idle, connecting, connected, closed
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var videoView: EdgeMetalVideoView

    private let bookmark: Bookmark
    private var peerConnection: EdgePeerConnection?
    private var videoTrack: EdgeVideoTrack?
    private var audioTrack: EdgeAudioTrack?

    var onStateChange: ((State) -> Void)?

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        self.videoView = EdgeMetalVideoView(frame: .zero)
        self.videoView.videoContentMode = .scaleAspectFit
    }

    func start(tracks: [String]) async {
        setState(.connecting)
        do {
            let connection = try await EdgeConnectionManager.shared.getConnection(bookmark)
            var pc = EdgeWebrtc.createPeerConnection(connection)

            pc.onTrack = { [weak self] track, _ in
                guard let self else { return }
                Task { @MainActor in self.attachIncomingTrack(track) }
            }
            pc.onError = { [weak self] error in
                Task { @MainActor in self?.setState(.failed("\(error)")) }
            }
            pc.onClosed = { [weak self] in
                Task { @MainActor in self?.setState(.closed) }
            }
            peerConnection = pc

            try await pc.connect()
            try await requestTracks(connection: connection, tracks: tracks)
            setState(.connected)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    func stop() async {
        if let track = videoTrack {
            track.remove(videoView)
            videoTrack = nil
        }
        audioTrack = nil
        if let pc = peerConnection {
            await pc.close()
            peerConnection = nil
        }
        setState(.closed)
    }

    private func attachIncomingTrack(_ track: EdgeMediaTrack) {
        if let video = track as? EdgeVideoTrack {
            videoTrack = video
            video.add(videoView)
        } else if let audio = track as? EdgeAudioTrack {
            audioTrack = audio
            audio.setEnabled(true)
        }
    }

    private func requestTracks(connection: Connection, tracks: [String]) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["tracks": tracks])
        let coap = try connection.createCoapRequest(method: "POST", path: "/webrtc/tracks")
        try coap.setRequestPayload(contentFormat: 50, data: json)
        let result = try await Task.detached(priority: .userInitiated) {
            try coap.execute()
        }.value
        guard result.status == 201 else {
            throw WebRtcSessionError.tracksRequestFailed(status: result.status)
        }
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }
}
