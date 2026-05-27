import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.nabto.EdgeWebRTCDemo", category: "AddDevice")

private func redactValue(_ secret: String?) -> String {
    guard let secret else { return "<nil>" }
    if secret.isEmpty { return "<empty>" }
    return "\(secret.prefix(2))..."
}

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    enum Mode: String, CaseIterable, Identifiable {
        case pairingString = "Pairing string"
        case fields = "Manual fields"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .pairingString
    @State private var pairingString: String = ""
    @State private var pairingError: String?

    @State private var productId: String = ""
    @State private var deviceId: String = ""
    @State private var sct: String = ""
    @State private var password: String = ""
    @State private var username: String = ""

    @State private var pendingInput: PairingInput?

    init(prefill: PairingInput? = nil) {
        if let prefill {
            _mode = State(initialValue: .fields)
            _productId = State(initialValue: prefill.productId)
            _deviceId = State(initialValue: prefill.deviceId)
            _sct = State(initialValue: prefill.sct ?? "")
            _password = State(initialValue: prefill.password ?? "")
            _username = State(initialValue: prefill.desiredUsername ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Input mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch mode {
                case .pairingString: pairingStringSection
                case .fields:        fieldsSection
                }

                Section {
                    Button("Pair") { startPairing() }
                        .frame(maxWidth: .infinity)
                        .disabled(!canPair)
                }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $pendingInput) { input in
                PairingView(input: input) { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var pairingStringSection: some View {
        Section("Pairing string") {
            TextField("p=...,d=...,pwd=...,sct=...", text: $pairingString, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .onChange(of: pairingString) { _, new in validateString(new) }
            if let pairingError {
                Text(pairingError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        Section("Optional") {
            TextField("Desired username on device", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var fieldsSection: some View {
        Section("Required") {
            TextField("Product ID (pr-...)", text: $productId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Device ID (de-...)", text: $deviceId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Section("Optional") {
            TextField("Server Connect Token (SCT)", text: $sct)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Pairing password", text: $password)
            TextField("Desired username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var canPair: Bool {
        switch mode {
        case .pairingString:
            return pairingError == nil && !pairingString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .fields:
            return productId.hasPrefix("pr-") && deviceId.hasPrefix("de-")
        }
    }

    private func validateString(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { pairingError = nil; return }
        do {
            _ = try parsePairingString(trimmed)
            pairingError = nil
        } catch {
            pairingError = error.localizedDescription
        }
    }

    private func startPairing() {
        switch mode {
        case .pairingString:
            let trimmed = pairingString.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("startPairing pairingString length=\(trimmed.count) head=\(trimmed.prefix(20), privacy: .public) tail=\(trimmed.suffix(8), privacy: .public)")
            do {
                let details = try parsePairingString(trimmed)
                log.info("parsed pairing string: product=\(details.productId, privacy: .public) device=\(details.deviceId, privacy: .public) sct=\(details.sct ?? "<nil>", privacy: .public) user=\(details.username ?? "<nil>", privacy: .public) pwd=\(redactValue(details.password), privacy: .public) fp=\(details.deviceFingerprint ?? "<nil>", privacy: .public)")
                pendingInput = PairingInput(
                    productId: details.productId,
                    deviceId: details.deviceId,
                    sct: details.sct,
                    password: details.password,
                    desiredUsername: nonEmpty(username) ?? details.username,
                    expectedFingerprint: details.deviceFingerprint
                )
            } catch {
                log.error("parse failed: \(error.localizedDescription, privacy: .public)")
                app.toaster.error("Invalid pairing string", message: error.localizedDescription)
            }
        case .fields:
            log.info("startPairing manual fields: product=\(productId, privacy: .public) device=\(deviceId, privacy: .public) sct=\(nonEmpty(sct) ?? "<nil>", privacy: .public) user=\(nonEmpty(username) ?? "<nil>", privacy: .public) pwd=\(redactValue(nonEmpty(password)), privacy: .public)")
            pendingInput = PairingInput(
                productId: productId,
                deviceId: deviceId,
                sct: nonEmpty(sct),
                password: nonEmpty(password),
                desiredUsername: nonEmpty(username)
            )
        }
    }

    private func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension PairingInput: Hashable {
    static func == (lhs: PairingInput, rhs: PairingInput) -> Bool {
        lhs.productId == rhs.productId && lhs.deviceId == rhs.deviceId
            && lhs.sct == rhs.sct && lhs.password == rhs.password
            && lhs.desiredUsername == rhs.desiredUsername
            && lhs.expectedFingerprint == rhs.expectedFingerprint
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(productId)
        hasher.combine(deviceId)
        hasher.combine(sct)
        hasher.combine(password)
        hasher.combine(desiredUsername)
        hasher.combine(expectedFingerprint)
    }
}

#Preview {
    AddDeviceView().environment(AppModel())
}
