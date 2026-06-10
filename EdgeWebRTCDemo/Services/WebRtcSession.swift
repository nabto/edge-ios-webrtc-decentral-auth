import Foundation
import OSLog
import Observation
import WebRTC
import NabtoEdgeClient
import NabtoEdgeClientWebRTC

private let log = Logger(subsystem: "com.nabto.EdgeWebRTCDemo", category: "WebRtcSession")

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

/// Captured at runtime; surfaced in `DeviceDetailView`'s diagnostics panel.
struct SessionDiagnostics: Equatable {
    var sdkVersion: String = ""
    var webrtcSdkVersion: String = ""
    var connectionType: String = "—"
    var clientFingerprint: String = "—"
    var deviceFingerprint: String = "—"
    var sctRedacted: String = "—"
    var tracksRequested: [String] = []
    var tracksReceived: [String] = []
    var videoFrameCount: Int = 0
    var videoFrameSize: CGSize = .zero
    var lastFrameAt: Date?
    var connectedAt: Date?
    var lastError: String?
    var stalled: Bool = false
    /// Video codecs the client's WebRTC build can decode. Useful for diagnosing
    /// codec-mismatch failures (e.g. device offers H.265 but client only has H.264).
    var clientVideoCodecs: [String] = []
    /// True if the last failure looks like a codec-negotiation failure
    /// (`setRemoteDescriptionError`), so the UI can show a tailored hint.
    var codecMismatchSuspected: Bool = false

    // MARK: - WebRTC inbound-rtp stats (polled from RTCPeerConnection.statistics)
    var rtpBytesReceived: UInt64 = 0
    var rtpPacketsReceived: Int = 0
    var rtpPacketsLost: Int = 0
    var rtpFramesReceived: Int = 0
    var rtpFramesDecoded: Int = 0
    var rtpKeyFramesReceived: Int = 0
    var rtpKeyFramesDecoded: Int = 0
    var rtpFrameWidth: Int = 0
    var rtpFrameHeight: Int = 0
    var rtpPliCount: Int = 0
    var rtpFirCount: Int = 0
    var rtpNackCount: Int = 0
    var rtpJitterMs: Double = 0
    var iceRttMs: Double = 0
    var iceLocalCandidateType: String = "—"
    var iceRemoteCandidateType: String = "—"
    var videoCodec: String = "—"
    var decoderImplementation: String = "—"
    /// Bitrate in bits per second, computed between consecutive stat polls.
    var bitrateBps: Double = 0

    var timeSinceLastFrame: TimeInterval? {
        guard let last = lastFrameAt else { return nil }
        return Date().timeIntervalSince(last)
    }

    var connectionAge: TimeInterval? {
        guard let connectedAt else { return nil }
        return Date().timeIntervalSince(connectedAt)
    }
}

/// Owns the `EdgePeerConnection` and remote tracks for a single device view.
///
/// Decentralized-IAM flavor: no `/webrtc/oauth` handshake — the Nabto connection
/// is already authenticated by the paired user's keypair, and the device-side
/// WebRTC handler uses the IAM role mapping to authorize media access.
@MainActor
@Observable
final class WebRtcSession {
    enum State: Equatable {
        case idle, connecting, connected, closed
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var diagnostics = SessionDiagnostics()
    let videoView: EdgeMetalVideoView

    private let bookmark: Bookmark
    private var peerConnection: EdgePeerConnection?
    private var videoTrack: EdgeVideoTrack?
    private var audioTrack: EdgeAudioTrack?
    private let frameCounter = FrameCountingRenderer()
    private var stallWatchdog: Task<Void, Never>?
    private var statsPoller: Task<Void, Never>?
    private var lastBytesReceived: UInt64 = 0
    private var lastStatsAt: Date?
    private var connectionClosedObserver: NSObjectProtocol?

    /// If `state == .connected` and no frame arrives for this long, flip to `.failed`.
    /// Catches the case where the Nabto tunnel is still alive but the device stopped
    /// sending media (the original "stuck thinking the device is online" complaint).
    private let frameStallThreshold: TimeInterval = 6

    var onStateChange: ((State) -> Void)?

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        self.videoView = EdgeMetalVideoView(frame: .zero)
        self.videoView.videoContentMode = .scaleAspectFit
        self.diagnostics.sdkVersion = Client.versionString()
        self.diagnostics.webrtcSdkVersion = "EdgeWebRTC"
        self.diagnostics.sctRedacted = redact(bookmark.sct)
        self.diagnostics.clientVideoCodecs = RTCDefaultVideoDecoderFactory()
            .supportedCodecs()
            .map { codec in
                if codec.parameters.isEmpty { return codec.name }
                let params = codec.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
                return "\(codec.name)(\(params))"
            }
        installNotificationObserver()
    }

    func start(tracks: [String]) async {
        log.info("start tracks=\(tracks.joined(separator: ","), privacy: .public) bookmark=\(self.bookmark.id, privacy: .public)")
        setState(.connecting)
        diagnostics.tracksRequested = tracks
        diagnostics.tracksReceived = []
        diagnostics.videoFrameCount = 0
        diagnostics.lastFrameAt = nil
        diagnostics.connectedAt = nil
        diagnostics.lastError = nil
        diagnostics.stalled = false

        do {
            let connection = try await EdgeConnectionManager.shared.getConnection(bookmark)
            updateConnectionDiagnostics(connection)

            var pc = EdgeWebrtc.createPeerConnection(connection)

            pc.onTrack = { [weak self] track, trackId in
                Task { @MainActor in self?.attachIncomingTrack(track, trackId: trackId) }
            }
            pc.onError = { [weak self] error in
                Task { @MainActor in self?.handleSdkError(error) }
            }
            pc.onClosed = { [weak self] in
                Task { @MainActor in
                    log.info("EdgePeerConnection.onClosed")
                    self?.setState(.closed)
                }
            }
            peerConnection = pc

            try await pc.connect()
            log.info("peer connection established")

            try await requestTracks(connection: connection, tracks: tracks)
            diagnostics.connectedAt = Date()
            setState(.connected)
            startStallWatchdog()
            startStatsPoller()
        } catch {
            recordError(error.localizedDescription)
            setState(.failed(error.localizedDescription))
        }
    }

    func stop() async {
        log.info("stop")
        stallWatchdog?.cancel()
        stallWatchdog = nil
        statsPoller?.cancel()
        statsPoller = nil
        lastBytesReceived = 0
        lastStatsAt = nil
        if let track = videoTrack {
            track.remove(videoView)
            track.remove(frameCounter)
            videoTrack = nil
        }
        audioTrack = nil
        if let pc = peerConnection {
            await pc.close()
            peerConnection = nil
        }
        setState(.closed)
    }

    func retry(tracks: [String]) async {
        log.info("retry tracks=\(tracks.joined(separator: ","), privacy: .public)")
        await stop()
        // Drop the cached connection so we definitely build a fresh one.
        await EdgeConnectionManager.shared.removeConnection(bookmark)
        await start(tracks: tracks)
    }

    // MARK: - Internals

    /// Translates raw SDK errors into a user-readable state and message, with
    /// special handling for codec-negotiation failures.
    private func handleSdkError(_ error: EdgeWebrtcError) {
        log.error("EdgeWebrtcError: \(String(describing: error), privacy: .public)")
        switch error {
        case .setRemoteDescriptionError:
            diagnostics.codecMismatchSuspected = true
            let supported = diagnostics.clientVideoCodecs
                .map { $0.split(separator: "(").first.map(String.init) ?? $0 }
                .reduce(into: Set<String>()) { $0.insert($1) }
                .sorted()
                .joined(separator: ", ")
            let message = "WebRTC negotiation failed (setRemoteDescription).\n\n" +
                "Most likely cause: the device offered a video codec this client cannot decode. " +
                "Check the Xcode console for 'No video codecs supported' from `webrtc_video_engine.cc` " +
                "and 'INVALID_PARAMETER' from `sdp_offer_answer.cc` for the rejected m-section.\n\n" +
                "Client supports: \(supported.isEmpty ? "<none>" : supported)."
            recordError(message)
            setState(.failed("Codec negotiation failed (likely unsupported codec)"))
        case .sendAnswerError where diagnostics.codecMismatchSuspected:
            // Follow-on failure after setRemoteDescription couldn't build an answer.
            // Don't overwrite the more useful codec-mismatch message.
            log.info("Suppressing sendAnswerError — already reported codec mismatch")
        case .sendAnswerError:
            recordError("Failed to send WebRTC answer on the signaling stream.")
            setState(.failed("Failed to send WebRTC answer"))
        case .signalingFailedToInitialize:
            recordError("Could not open the WebRTC signaling stream to the device.")
            setState(.failed("Signaling failed to initialize"))
        case .signalingFailedRecv:
            recordError("Signaling stream stopped receiving (device offline?).")
            setState(.failed("Signaling read failed"))
        case .signalingFailedSend:
            recordError("Signaling stream stopped accepting writes.")
            setState(.failed("Signaling write failed"))
        case .signalingInvalidMessage:
            recordError("Received an invalid signaling message from the device.")
            setState(.failed("Invalid signaling message"))
        case .iceCandidateError:
            recordError("Invalid ICE candidate received from the device.")
            setState(.failed("Invalid ICE candidate"))
        case .connectionInitError:
            recordError("Failed to create the RTCPeerConnection.")
            setState(.failed("Peer connection init failed"))
        @unknown default:
            recordError("WebRTC error: \(error)")
            setState(.failed("\(error)"))
        }
    }

    private func attachIncomingTrack(_ track: EdgeMediaTrack, trackId: String?) {
        let label = trackId ?? "<unknown>"
        log.info("onTrack id=\(label, privacy: .public) type=\(String(describing: type(of: track)), privacy: .public)")
        diagnostics.tracksReceived.append(label)
        if let video = track as? EdgeVideoTrack {
            videoTrack = video
            video.add(videoView)
            // Attach a side renderer to count frames + sizes for diagnostics.
            frameCounter.onFrame = { [weak self] size in
                Task { @MainActor in self?.handleFrame(size: size) }
            }
            video.add(frameCounter)
        } else if let audio = track as? EdgeAudioTrack {
            audioTrack = audio
            audio.setEnabled(true)
        }
    }

    private func handleFrame(size: CGSize) {
        diagnostics.videoFrameCount += 1
        diagnostics.videoFrameSize = size
        diagnostics.lastFrameAt = Date()
        if diagnostics.stalled {
            diagnostics.stalled = false
            log.info("stream un-stalled at frame \(self.diagnostics.videoFrameCount, privacy: .public)")
        }
    }

    private func updateConnectionDiagnostics(_ connection: Connection) {
        do {
            diagnostics.deviceFingerprint = try connection.getDeviceFingerprintHex()
        } catch { diagnostics.deviceFingerprint = "<err>" }
        do {
            diagnostics.clientFingerprint = try connection.getClientFingerprintHex()
        } catch { diagnostics.clientFingerprint = "<err>" }
        do {
            let type = try connection.getType()
            diagnostics.connectionType = String(describing: type)
        } catch { diagnostics.connectionType = "<err>" }
        log.info("connection type=\(self.diagnostics.connectionType, privacy: .public) deviceFp=\(self.diagnostics.deviceFingerprint, privacy: .public) clientFp=\(self.diagnostics.clientFingerprint, privacy: .public)")
    }

    private func requestTracks(connection: Connection, tracks: [String]) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["tracks": tracks])
        let coap = try connection.createCoapRequest(method: "POST", path: "/webrtc/tracks")
        try coap.setRequestPayload(contentFormat: 50, data: json)
        log.info("POST /webrtc/tracks tracks=\(tracks.joined(separator: ","), privacy: .public)")
        let result = try await Task.detached(priority: .userInitiated) {
            try coap.execute()
        }.value
        log.info("/webrtc/tracks result status=\(result.status, privacy: .public)")
        guard result.status == 201 else {
            throw WebRtcSessionError.tracksRequestFailed(status: result.status)
        }
    }

    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self, frameStallThreshold] in
            // Allow up to threshold seconds for the first frame.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run { self.evaluateStall(threshold: frameStallThreshold) }
            }
        }
    }

    private func evaluateStall(threshold: TimeInterval) {
        guard case .connected = state else { return }
        let elapsed: TimeInterval
        if let last = diagnostics.lastFrameAt {
            elapsed = Date().timeIntervalSince(last)
        } else if let connectedAt = diagnostics.connectedAt {
            elapsed = Date().timeIntervalSince(connectedAt)
        } else {
            return
        }
        if elapsed > threshold && !diagnostics.stalled {
            diagnostics.stalled = true
            let reason = stallReason(elapsedSec: Int(elapsed))
            log.error("stall detected: \(reason, privacy: .public)")
            recordError(reason)
            setState(.failed(reason))
        }
    }

    /// Build the most specific stall message we can given current RTP stats.
    /// Distinguishes "no packets arrived" from "packets but no decoded frames"
    /// from "decoded frames but our renderer didn't see them".
    private func stallReason(elapsedSec: Int) -> String {
        let pkts = diagnostics.rtpPacketsReceived
        let bytes = diagnostics.rtpBytesReceived
        let framesDec = diagnostics.rtpFramesDecoded
        let kfReceived = diagnostics.rtpKeyFramesReceived

        if pkts == 0 && bytes == 0 {
            return "No SRTP packets received \(elapsedSec)s after connect. WebRTC is set up but the device hasn't sent any media — most likely the device-side bridge from the camera/RTSP into the WebRTC track is broken."
        }
        if framesDec == 0 {
            return "\(pkts) packets received but 0 frames decoded \(elapsedSec)s after connect. " +
                (kfReceived == 0
                    ? "No keyframe has arrived yet — request one via PLI, or check the device's encoder is producing IDR/IRAP frames."
                    : "Keyframes received (\(kfReceived)) but the H.265 decoder didn't produce output — bitstream may be malformed.")
        }
        if diagnostics.videoFrameCount == 0 && framesDec > 0 {
            return "Decoder produced \(framesDec) frames but our renderer never received any. Renderer-side issue (track-to-view wiring)."
        }
        return "No video frames for \(elapsedSec)s. The device may have gone offline."
    }

    // MARK: - getStats() polling

    private func startStatsPoller() {
        statsPoller?.cancel()
        statsPoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchStatsOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func fetchStatsOnce() async {
        guard let rtcPC = peerConnection?.getPeerConnection() else { return }
        let report = await withCheckedContinuation { (cont: CheckedContinuation<RTCStatisticsReport, Never>) in
            rtcPC.statistics { cont.resume(returning: $0) }
        }
        applyStats(report)
    }

    private func applyStats(_ report: RTCStatisticsReport) {
        var codecId: String?
        var selectedCandidatePairId: String?
        var sawVideoInbound = false

        for stat in report.statistics.values where stat.type == "transport" {
            selectedCandidatePairId = stat.values["selectedCandidatePairId"] as? String
        }

        for stat in report.statistics.values {
            switch stat.type {
            case "inbound-rtp":
                guard let kind = stat.values["kind"] as? String, kind == "video" else { continue }
                sawVideoInbound = true
                if let v = (stat.values["bytesReceived"] as? NSNumber)?.uint64Value {
                    diagnostics.rtpBytesReceived = v
                    let now = Date()
                    if let last = lastStatsAt {
                        let elapsed = now.timeIntervalSince(last)
                        if elapsed > 0 && v > lastBytesReceived {
                            diagnostics.bitrateBps = Double(v - lastBytesReceived) * 8 / elapsed
                        } else if v == lastBytesReceived {
                            diagnostics.bitrateBps = 0
                        }
                    }
                    lastBytesReceived = v
                    lastStatsAt = now
                }
                if let v = (stat.values["packetsReceived"] as? NSNumber)?.intValue { diagnostics.rtpPacketsReceived = v }
                if let v = (stat.values["packetsLost"] as? NSNumber)?.intValue { diagnostics.rtpPacketsLost = v }
                if let v = (stat.values["framesReceived"] as? NSNumber)?.intValue { diagnostics.rtpFramesReceived = v }
                if let v = (stat.values["framesDecoded"] as? NSNumber)?.intValue { diagnostics.rtpFramesDecoded = v }
                if let v = (stat.values["keyFramesReceived"] as? NSNumber)?.intValue { diagnostics.rtpKeyFramesReceived = v }
                if let v = (stat.values["keyFramesDecoded"] as? NSNumber)?.intValue { diagnostics.rtpKeyFramesDecoded = v }
                if let v = (stat.values["frameWidth"] as? NSNumber)?.intValue { diagnostics.rtpFrameWidth = v }
                if let v = (stat.values["frameHeight"] as? NSNumber)?.intValue { diagnostics.rtpFrameHeight = v }
                if let v = (stat.values["pliCount"] as? NSNumber)?.intValue { diagnostics.rtpPliCount = v }
                if let v = (stat.values["firCount"] as? NSNumber)?.intValue { diagnostics.rtpFirCount = v }
                if let v = (stat.values["nackCount"] as? NSNumber)?.intValue { diagnostics.rtpNackCount = v }
                if let v = (stat.values["jitter"] as? NSNumber)?.doubleValue { diagnostics.rtpJitterMs = v * 1000 }
                if let v = stat.values["decoderImplementation"] as? String { diagnostics.decoderImplementation = v }
                codecId = stat.values["codecId"] as? String

            case "candidate-pair":
                if stat.id == selectedCandidatePairId,
                   let rtt = (stat.values["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                    diagnostics.iceRttMs = rtt * 1000
                }

            default:
                break
            }
        }

        // Look up codec mime + candidate types in a second pass (need lookups by id).
        if let codecId,
           let codecStat = report.statistics[codecId],
           let mime = codecStat.values["mimeType"] as? String {
            diagnostics.videoCodec = mime.components(separatedBy: "/").last ?? mime
        }
        if let pairId = selectedCandidatePairId,
           let pair = report.statistics[pairId] {
            if let lcId = pair.values["localCandidateId"] as? String,
               let lc = report.statistics[lcId],
               let t = lc.values["candidateType"] as? String {
                diagnostics.iceLocalCandidateType = t
            }
            if let rcId = pair.values["remoteCandidateId"] as? String,
               let rc = report.statistics[rcId],
               let t = rc.values["candidateType"] as? String {
                diagnostics.iceRemoteCandidateType = t
            }
        }

        if !sawVideoInbound {
            // Reset so the UI doesn't show stale values from a previous session.
            // Only clear if we currently don't have any inbound stats at all.
            if diagnostics.rtpBytesReceived == 0 && diagnostics.rtpPacketsReceived == 0 {
                lastBytesReceived = 0
                lastStatsAt = nil
            }
        }
    }

    private func recordError(_ message: String) {
        diagnostics.lastError = message
        log.error("\(message, privacy: .public)")
    }

    private func installNotificationObserver() {
        let targetId = bookmark.id
        connectionClosedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(EdgeConnectionManager.eventNameConnectionClosed),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let posted = note.object as? Bookmark, posted.id == targetId else { return }
            Task { @MainActor in
                guard let self else { return }
                log.info("CLOSED notification for our bookmark")
                self.recordError("Connection closed by SDK/network.")
                self.setState(.closed)
            }
        }
    }

    private func setState(_ new: State) {
        if state == new { return }
        log.info("state \(String(describing: self.state), privacy: .public) -> \(String(describing: new), privacy: .public)")
        state = new
        onStateChange?(new)
    }
}

// MARK: - Side renderer that counts frames for diagnostics

private final class FrameCountingRenderer: NSObject, EdgeVideoRenderer {
    var lastSize: CGSize = .zero
    /// Called on the video thread when a new frame is rendered.
    var onFrame: ((CGSize) -> Void)?

    func setSize(_ size: CGSize) {
        lastSize = size
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        onFrame?(lastSize)
    }
}

// MARK: - Helpers

private func redact(_ secret: String?) -> String {
    guard let secret, !secret.isEmpty else { return "—" }
    if secret.count <= 4 { return "\(secret.prefix(2))..." }
    return "\(secret.prefix(4))..."
}
