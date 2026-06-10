import SwiftUI

struct DeviceDetailView: View {
    let bookmark: Bookmark

    @Environment(AppModel.self) private var app
    @State private var session: WebRtcSession
    @State private var showTracksEditor = false
    @State private var tracksDraft: String = ""
    @State private var clockTick = Date()
    @State private var clockTimer: Timer?

    private static let defaultTracks = ["frontdoor-video", "frontdoor-audio"]

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _session = State(initialValue: WebRtcSession(bookmark: bookmark))
    }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusBar
                    diagnosticsPanel
                }
            }
        }
        .navigationTitle(bookmark.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await session.retry(tracks: currentTracks) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reconnect")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    tracksDraft = currentTracks.joined(separator: ", ")
                    showTracksEditor = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("Edit tracks")
            }
        }
        .sheet(isPresented: $showTracksEditor) { tracksEditor }
        .task {
            await session.start(tracks: currentTracks)
        }
        .onDisappear {
            clockTimer?.invalidate()
            clockTimer = nil
            Task { await session.stop() }
        }
        .onAppear {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in clockTick = Date() }
            }
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            MetalVideoRepresentable(view: session.videoView)
            overlayForState
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var overlayForState: some View {
        switch session.state {
        case .idle, .connecting:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Connecting...")
                    .foregroundStyle(.white)
            }
        case .connected:
            if session.diagnostics.videoFrameCount == 0 {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Waiting for first frame...")
                        .foregroundStyle(.white)
                }
            }
        case .closed:
            Label("Disconnected", systemImage: "stop.circle")
                .foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.yellow)
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    Task { await session.retry(tracks: currentTracks) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.subheadline)
                Spacer()
                Text("\(bookmark.productId).\(bookmark.deviceId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("Tracks:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(currentTracks.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            if let role = bookmark.role {
                Text("Role on device: \(role)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Connection")
            diagRow("Nabto SDK", session.diagnostics.sdkVersion)
            diagRow("Connection type", session.diagnostics.connectionType)
            diagRow("Stream state", statusText)
            diagRow("Connected for", formatDuration(session.diagnostics.connectionAge))

            sectionHeader("Identity")
            diagRow("Product ID", bookmark.productId)
            diagRow("Device ID", bookmark.deviceId)
            diagRow("Device fingerprint", truncate(session.diagnostics.deviceFingerprint, head: 16))
            diagRow("Client fingerprint", truncate(session.diagnostics.clientFingerprint, head: 16))
            diagRow("SCT", session.diagnostics.sctRedacted)
            if let role = bookmark.role { diagRow("Role", role) }

            sectionHeader("Media")
            diagRow("Tracks requested",
                    session.diagnostics.tracksRequested.isEmpty
                        ? "—"
                        : session.diagnostics.tracksRequested.joined(separator: ", "))
            diagRow("Tracks received",
                    session.diagnostics.tracksReceived.isEmpty
                        ? "—"
                        : session.diagnostics.tracksReceived.joined(separator: ", "))
            diagRow("Renderer frames", "\(session.diagnostics.videoFrameCount)")
            diagRow("Renderer last frame", formatAge(session.diagnostics.lastFrameAt))
            diagRow("Stalled",
                    session.diagnostics.stalled ? "yes" : "no",
                    valueColor: session.diagnostics.stalled ? .red : .secondary)

            sectionHeader("Inbound RTP (video)")
            diagRow("Codec", session.diagnostics.videoCodec)
            diagRow("Decoder", session.diagnostics.decoderImplementation)
            diagRow("Frame size",
                    session.diagnostics.rtpFrameWidth == 0
                        ? "—"
                        : "\(session.diagnostics.rtpFrameWidth)×\(session.diagnostics.rtpFrameHeight)")
            diagRow("Bytes received", formatBytes(session.diagnostics.rtpBytesReceived))
            diagRow("Bitrate", formatBitrate(session.diagnostics.bitrateBps))
            diagRow("Packets received", "\(session.diagnostics.rtpPacketsReceived)",
                    valueColor: session.diagnostics.rtpPacketsReceived == 0 && session.state == .connected ? .red : .primary)
            diagRow("Packets lost", "\(session.diagnostics.rtpPacketsLost)")
            diagRow("Frames received", "\(session.diagnostics.rtpFramesReceived)")
            diagRow("Frames decoded", "\(session.diagnostics.rtpFramesDecoded)",
                    valueColor: session.diagnostics.rtpFramesDecoded == 0 && session.diagnostics.rtpPacketsReceived > 0 ? .red : .primary)
            diagRow("Keyframes received", "\(session.diagnostics.rtpKeyFramesReceived)")
            diagRow("Keyframes decoded", "\(session.diagnostics.rtpKeyFramesDecoded)")
            diagRow("PLI / FIR / NACK",
                    "\(session.diagnostics.rtpPliCount) / \(session.diagnostics.rtpFirCount) / \(session.diagnostics.rtpNackCount)")
            diagRow("Jitter (ms)", String(format: "%.1f", session.diagnostics.rtpJitterMs))

            sectionHeader("ICE")
            diagRow("Local candidate", session.diagnostics.iceLocalCandidateType)
            diagRow("Remote candidate", session.diagnostics.iceRemoteCandidateType)
            diagRow("RTT (ms)", String(format: "%.0f", session.diagnostics.iceRttMs))

            sectionHeader("Client video codecs")
            if session.diagnostics.clientVideoCodecs.isEmpty {
                Text("—").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.diagnostics.clientVideoCodecs, id: \.self) { codec in
                        Text(codec)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal)
            }

            if session.diagnostics.codecMismatchSuspected {
                sectionHeader("Codec negotiation failed")
                VStack(alignment: .leading, spacing: 4) {
                    Label("Client cannot decode the device's video codec", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Compare the codec list above against what the device offers in the Xcode console SDP trace. Reconfigure the device to offer a codec from the supported list, or extend the client-side decoder factory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            if let lastError = session.diagnostics.lastError {
                sectionHeader("Last error")
                Text(lastError)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }

            Spacer(minLength: 24)
        }
        .padding(.vertical)
        // touch clockTick so SwiftUI re-renders the "last frame: 3s ago" rows every second
        .id("diag-\(clockTick.timeIntervalSinceReferenceDate.rounded())")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 8)
    }

    private func diagRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = true,
        valueColor: Color = .primary,
        skipIfEmpty: Bool = false
    ) -> some View {
        Group {
            if skipIfEmpty && (value == "—" || value.isEmpty) {
                EmptyView()
            } else {
                HStack(alignment: .top) {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(value)
                        .font(monospaced ? .footnote.monospaced() : .footnote)
                        .foregroundStyle(valueColor)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Tracks editor

    private var tracksEditor: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. frontdoor-video, frontdoor-audio", text: $tracksDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Track names")
                } footer: {
                    Text("Comma-separated track IDs to request via CoAP POST /webrtc/tracks. Defaults match the existing Nabto WebRTC demo device firmware.")
                        .font(.footnote)
                }
                Section {
                    Button("Apply and reconnect") {
                        applyTracks()
                    }
                    Button("Reset to defaults", role: .destructive) {
                        tracksDraft = Self.defaultTracks.joined(separator: ", ")
                    }
                }
            }
            .navigationTitle("Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showTracksEditor = false }
                }
            }
        }
    }

    private var currentTracks: [String] {
        bookmark.tracks ?? Self.defaultTracks
    }

    private func applyTracks() {
        let parsed = tracksDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parsed.isEmpty else {
            app.toaster.warning("Tracks list cannot be empty")
            return
        }
        bookmark.tracks = parsed
        do { try app.bookmarks.update(bookmark) }
        catch { app.toaster.error("Could not save tracks", message: error.localizedDescription) }
        showTracksEditor = false
        Task { await session.retry(tracks: parsed) }
    }

    private var statusColor: Color {
        if session.diagnostics.stalled { return .red }
        switch session.state {
        case .idle, .connecting: return .yellow
        case .connected:         return .green
        case .closed:            return .gray
        case .failed:            return .red
        }
    }

    private var statusText: String {
        if session.diagnostics.stalled { return "Stalled (no frames)" }
        switch session.state {
        case .idle:           return "Idle"
        case .connecting:     return "Connecting"
        case .connected:      return "Connected"
        case .closed:         return "Disconnected"
        case .failed(let m):  return "Failed: \(m)"
        }
    }

    // MARK: - Formatting

    private func truncate(_ s: String, head: Int) -> String {
        guard s.count > head else { return s }
        return "\(s.prefix(head))…"
    }

    private func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private func formatAge(_ date: Date?) -> String {
        guard let date else { return "—" }
        let age = Date().timeIntervalSince(date)
        if age < 1 { return "just now" }
        if age < 60 { return "\(Int(age))s ago" }
        return formatDuration(age) + " ago"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }
        let units = ["B", "kB", "MB", "GB"]
        var value = Double(bytes)
        var unitIdx = 0
        while value >= 1024 && unitIdx < units.count - 1 {
            value /= 1024
            unitIdx += 1
        }
        return String(format: unitIdx == 0 ? "%.0f %@" : "%.1f %@", value, units[unitIdx])
    }

    private func formatBitrate(_ bps: Double) -> String {
        if bps < 1 { return "0 bps" }
        if bps < 1_000 { return String(format: "%.0f bps", bps) }
        if bps < 1_000_000 { return String(format: "%.1f kbps", bps / 1_000) }
        return String(format: "%.2f Mbps", bps / 1_000_000)
    }
}

#Preview {
    NavigationStack {
        DeviceDetailView(bookmark: Bookmark(deviceId: "de-demo", productId: "pr-demo", name: "Demo"))
    }
    .environment(AppModel())
}
