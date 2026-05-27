import SwiftUI

struct DeviceDetailView: View {
    let bookmark: Bookmark

    @Environment(AppModel.self) private var app
    @State private var session: WebRtcSession
    @State private var state: WebRtcSession.State = .idle
    @State private var showTracksEditor = false
    @State private var tracksDraft: String = ""

    private static let defaultTracks = ["frontdoor-video", "frontdoor-audio"]

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _session = State(initialValue: WebRtcSession(bookmark: bookmark))
    }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            statusBar
        }
        .navigationTitle(bookmark.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            session.onStateChange = { state = $0 }
            await session.start(tracks: currentTracks)
        }
        .onDisappear {
            Task { await session.stop() }
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
        switch state {
        case .idle, .connecting:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Connecting...")
                    .foregroundStyle(.white)
            }
        case .connected:
            EmptyView()
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
                    Task {
                        await session.stop()
                        await session.start(tracks: currentTracks)
                    }
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
        do {
            try app.bookmarks.update(bookmark)
        } catch {
            app.toaster.error("Could not save tracks", message: error.localizedDescription)
        }
        showTracksEditor = false
        Task {
            await session.stop()
            await session.start(tracks: parsed)
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle, .connecting: return .yellow
        case .connected:         return .green
        case .closed:            return .gray
        case .failed:            return .red
        }
    }

    private var statusText: String {
        switch state {
        case .idle:           return "Idle"
        case .connecting:     return "Connecting"
        case .connected:      return "Connected"
        case .closed:         return "Disconnected"
        case .failed(let m):  return "Failed: \(m)"
        }
    }
}

#Preview {
    NavigationStack {
        DeviceDetailView(bookmark: Bookmark(deviceId: "de-demo", productId: "pr-demo", name: "Demo"))
    }
    .environment(AppModel())
}
