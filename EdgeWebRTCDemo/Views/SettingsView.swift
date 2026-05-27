import SwiftUI
import NabtoEdgeClient
import NabtoEdgeClientWebRTC

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var showClearAlert = false
    @State private var showRegenAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bookmarks") {
                    Button("Clear all bookmarks", role: .destructive) {
                        showClearAlert = true
                    }
                    .disabled(app.bookmarks.bookmarks.isEmpty)
                }

                Section {
                    Button("Regenerate client keypair", role: .destructive) {
                        showRegenAlert = true
                    }
                } header: {
                    Text("Client identity")
                } footer: {
                    Text("The keypair represents this app's identity to all paired devices. Regenerating it invalidates every existing pairing; each device must be re-paired (or factory-reset).")
                        .font(.footnote)
                }

                Section("About") {
                    LabeledContent("Nabto Edge Client", value: Client.versionString())
                    LabeledContent("App version", value: Bundle.main.shortVersion)
                    LabeledContent("Build", value: Bundle.main.build)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Clear all bookmarks?", isPresented: $showClearAlert) {
                Button("Clear", role: .destructive, action: clearBookmarks)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all paired devices from the app. The devices themselves are not affected and will keep your client paired.")
            }
            .alert("Regenerate keypair?", isPresented: $showRegenAlert) {
                Button("Regenerate", role: .destructive, action: regenerate)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All current pairings will become unusable. You will need to re-pair each device (factory reset may be required).")
            }
        }
    }

    private func clearBookmarks() {
        do {
            try app.bookmarks.clear()
            Task { await EdgeConnectionManager.shared.reset() }
            app.toaster.info("All bookmarks removed")
        } catch {
            app.toaster.error("Failed to clear bookmarks", message: error.localizedDescription)
        }
    }

    private func regenerate() {
        Task {
            await EdgeConnectionManager.shared.reset()
            do {
                let client = await EdgeConnectionManager.shared.client
                _ = try ProfileStore.shared.regenerate(using: client)
                app.toaster.success("New keypair generated", message: "Re-pair your devices to use them again.")
            } catch {
                app.toaster.error("Could not regenerate keypair", message: error.localizedDescription)
            }
        }
    }
}

private extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?" }
    var build: String { (infoDictionary?["CFBundleVersion"] as? String) ?? "?" }
}

#Preview {
    SettingsView().environment(AppModel())
}
