import Foundation
import Observation
import NabtoEdgeClient

struct DiscoveredDevice: Identifiable, Hashable {
    let productId: String
    let deviceId: String
    let serviceInstanceName: String?
    var id: String { "\(productId).\(deviceId)" }
}

@Observable
@MainActor
final class MdnsService {
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var scanning: Bool = false

    private var scanner: MdnsScanner?
    private var receiver: ResultReceiver?

    init() {}

    func start() async {
        let client = await EdgeConnectionManager.shared.client
        let scanner = client.createMdnsScanner()
        let receiver = ResultReceiver { [weak self] result in
            Task { @MainActor in self?.add(result) }
        }
        scanner.addMdnsResultReceiver(receiver)
        do {
            try scanner.start()
            self.scanner = scanner
            self.receiver = receiver
            self.scanning = true
        } catch {
            print("mDNS start failed: \(error)")
        }
    }

    func stop() {
        scanner?.stop()
        if let receiver { scanner?.removeMdnsResultReceiver(receiver) }
        scanner = nil
        receiver = nil
        scanning = false
    }

    func reset() {
        devices.removeAll()
    }

    private func add(_ result: MdnsResult) {
        guard let productId = result.productId, let deviceId = result.deviceId else { return }
        let entry = DiscoveredDevice(
            productId: productId,
            deviceId: deviceId,
            serviceInstanceName: result.serviceInstanceName
        )
        if !devices.contains(where: { $0.id == entry.id }) {
            devices.append(entry)
        }
    }

    private final class ResultReceiver: MdnsResultReceiver {
        let onResult: (MdnsResult) -> Void
        init(_ onResult: @escaping (MdnsResult) -> Void) { self.onResult = onResult }
        func onResultReady(result: MdnsResult) { onResult(result) }
    }
}
