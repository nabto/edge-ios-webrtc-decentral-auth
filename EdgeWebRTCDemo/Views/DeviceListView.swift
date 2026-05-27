import SwiftUI

struct DeviceListView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var showDiscover = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if app.bookmarks.bookmarks.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showDiscover = true } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                .accessibilityLabel("Discover local devices")
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add device")
            }
        }
        .sheet(isPresented: $showAdd) { AddDeviceView() }
        .sheet(isPresented: $showDiscover) { DiscoverView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No paired devices yet")
                .font(.headline)
            Text("Use Add to paste a pairing string, or Discover to find devices on your local network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack {
                Button("Add device") { showAdd = true }
                    .buttonStyle(.borderedProminent)
                Button("Discover") { showDiscover = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var list: some View {
        List {
            ForEach(app.bookmarks.bookmarks) { bookmark in
                NavigationLink(value: bookmark) {
                    DeviceRow(bookmark: bookmark)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationDestination(for: Bookmark.self) { DeviceDetailView(bookmark: $0) }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let bookmark = app.bookmarks.bookmarks[index]
            do {
                try app.bookmarks.remove(bookmark)
                Task { await EdgeConnectionManager.shared.removeConnection(bookmark) }
            } catch {
                app.toaster.error("Could not remove bookmark", message: error.localizedDescription)
            }
        }
    }
}

private struct DeviceRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .foregroundStyle(.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name)
                    .font(.headline)
                Text("\(bookmark.productId).\(bookmark.deviceId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let role = bookmark.role {
                    Text("Role: \(role)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        DeviceListView()
    }
    .environment(AppModel())
}
