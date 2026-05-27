import SwiftUI

struct PairingView: View {
    let input: PairingInput
    var onSuccess: () -> Void = {}

    @Environment(AppModel.self) private var app
    @State private var state: PairingState = .idle
    @State private var username: String = ""
    @State private var paired: Bookmark?

    enum PairingState: Equatable {
        case idle, working, success, failed(String)
    }

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Product", value: input.productId)
                LabeledContent("Device", value: input.deviceId)
                if input.sct != nil {
                    LabeledContent("SCT", value: "present")
                }
                if input.password != nil {
                    LabeledContent("Password", value: "from pairing string")
                }
            }
            Section {
                TextField("Username on device", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(state == .working)
            } header: {
                Text("Your identity")
            } footer: {
                Text("Used for IAM pairing. Only lower-case letters, digits, '.', '_' and '-' are allowed; other characters are replaced.")
                    .font(.footnote)
            }

            Section {
                switch state {
                case .idle, .failed:
                    Button("Confirm pairing", action: startPairing)
                        .frame(maxWidth: .infinity)
                case .working:
                    HStack {
                        ProgressView()
                        Text("Pairing...").foregroundStyle(.secondary)
                    }
                case .success:
                    Label("Paired", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if case .failed(let message) = state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let paired {
                Section {
                    NavigationLink("Open device", value: paired)
                }
            }
        }
        .navigationTitle("Pair device")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Bookmark.self) { DeviceDetailView(bookmark: $0) }
        .onAppear {
            if username.isEmpty {
                username = input.desiredUsername ?? UIDevice.current.name
            }
        }
    }

    private func startPairing() {
        state = .working
        let preparedInput = PairingInput(
            productId: input.productId,
            deviceId: input.deviceId,
            sct: input.sct,
            password: input.password,
            desiredUsername: username,
            expectedFingerprint: input.expectedFingerprint
        )
        Task {
            do {
                let bookmark = try await PairingService.pair(input: preparedInput, into: app.bookmarks)
                state = .success
                paired = bookmark
                app.toaster.success("Paired with \(bookmark.name)")
                onSuccess()
            } catch {
                state = .failed(error.localizedDescription)
                app.toaster.error("Pairing failed", message: error.localizedDescription)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PairingView(input: PairingInput(
            productId: "pr-demo",
            deviceId: "de-demo",
            sct: "demosct",
            password: nil,
            desiredUsername: "alice"
        ))
    }
    .environment(AppModel())
}
