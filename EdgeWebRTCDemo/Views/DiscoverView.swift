import SwiftUI

struct DiscoverView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var service = MdnsService()
    @State private var pendingInput: PairingInput?

    var body: some View {
        NavigationStack {
            Group {
                if service.devices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(service.scanning ? "Stop" : "Scan") {
                        Task {
                            if service.scanning {
                                service.stop()
                            } else {
                                service.reset()
                                await service.start()
                            }
                        }
                    }
                }
            }
            .navigationDestination(item: $pendingInput) { input in
                PairingView(input: input) { dismiss() }
            }
        }
        .task {
            await service.start()
        }
        .onDisappear {
            service.stop()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if service.scanning {
                ProgressView()
                Text("Scanning local network...")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No devices found")
                    .font(.headline)
                Text("Make sure your iPhone and the device are on the same Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private var deviceList: some View {
        List(service.devices) { device in
            Button {
                pendingInput = PairingInput(
                    productId: device.productId,
                    deviceId: device.deviceId,
                    sct: nil,
                    password: nil,
                    desiredUsername: nil
                )
            } label: {
                VStack(alignment: .leading) {
                    Text(device.serviceInstanceName ?? "Nabto Edge device")
                        .font(.headline)
                    Text("\(device.productId).\(device.deviceId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    DiscoverView().environment(AppModel())
}
