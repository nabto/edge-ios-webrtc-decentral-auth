import Foundation
import Network
import OSLog
import NabtoEdgeClient

private let log = Logger(subsystem: "com.nabto.EdgeWebRTCDemo", category: "EdgeConnection")

enum DeviceError: LocalizedError {
    /// The device's public-key fingerprint changed since we paired with it.
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .identityChanged:
            return "Device identity changed since pairing. Re-pair to continue."
        }
    }
}

private extension NWPathMonitor {
    func paths() -> AsyncStream<NWPath> {
        AsyncStream { continuation in
            self.pathUpdateHandler = { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            start(queue: DispatchQueue(label: "NWPathMonitor.paths"))
        }
    }
}

private final class ConnectionWrapper: ConnectionEventReceiver {
    var isClosed = false
    let target: Bookmark
    let connection: Connection

    init(target: Bookmark, connection: Connection) throws {
        self.target = target
        self.connection = connection
        try connection.addConnectionEventsReceiver(cb: self)
    }

    func onEvent(event: NabtoEdgeClientConnectionEvent) {
        log.info("connection event for \(self.target.id, privacy: .public): \(String(describing: event), privacy: .public)")
        if event == NabtoEdgeClientConnectionEvent.CLOSED {
            isClosed = true
            let bookmark = target
            Task { await EdgeConnectionManager.shared.evict(bookmark) }
            NotificationCenter.default.post(
                name: NSNotification.Name(EdgeConnectionManager.eventNameConnectionClosed),
                object: target
            )
        }
    }

    func stop() {
        connection.removeConnectionEventsReceiver(cb: self)
        connection.stop()
    }
}

actor EdgeConnectionManager {
    static let eventNameConnectionClosed = "EDGE_CONNECTION_CLOSED"
    static let eventNameNoNetwork        = "EDGE_NO_NETWORK"
    static let eventNameNetworkAvailable = "EDGE_NETWORK_AVAILABLE"

    static let shared = EdgeConnectionManager()

    private var cache: [Bookmark: ConnectionWrapper] = [:]
    private var client_: Client?
    private let logLevel = "trace"
    private let monitor = NWPathMonitor()
    private var networkAvailable = true

    private init() {
        Task { [monitor] in
            for await path in monitor.paths() {
                await self.handleNetworkPathUpdated(path)
            }
        }
    }

    var client: Client {
        if let existing = client_ { return existing }
        let fresh = Client()
        try? fresh.setLogLevel(level: logLevel)
        fresh.setLogCallBack { msg in
            print("[Nabto \(msg.severityString)] \(msg.file):\(msg.line) \(msg.message)")
        }
        log.info("Initialized Nabto Edge Client SDK \(Client.versionString(), privacy: .public) level=\(self.logLevel, privacy: .public)")
        client_ = fresh
        return fresh
    }

    func getConnection(_ target: Bookmark) async throws -> Connection {
        if let cached = cache[target], !cached.isClosed {
            return cached.connection
        }
        let conn = try await doConnect(target)
        cache[target] = try ConnectionWrapper(target: target, connection: conn)
        return conn
    }

    /// Build a connection for an unpaired device. Used by the pairing flow before
    /// we have a fingerprint or role for the bookmark. Not cached.
    func makeUnpairedConnection(productId: String, deviceId: String, sct: String?) throws -> Connection {
        let conn = try client.createConnection()
        try conn.setProductId(id: productId)
        try conn.setDeviceId(id: deviceId)
        try conn.setPrivateKey(key: try ProfileStore.shared.privateKey(using: client))
        if let sct { try conn.setServerConnectToken(sct: sct) }
        return conn
    }

    func removeConnection(_ target: Bookmark) async {
        let cached = cache.removeValue(forKey: target)
        cached?.stop()
    }

    /// Stop and drop every cached connection, but keep the `Client` alive.
    /// Triggers a `CLOSED` event for each, which any active view can react to.
    func closeAllConnections() async {
        log.info("closeAllConnections (\(self.cache.count, privacy: .public) cached)")
        for (_, value) in cache { value.stop() }
        cache.removeAll()
    }

    func reset() async {
        log.info("reset client + all connections")
        for (_, value) in cache { value.stop() }
        cache.removeAll()
        client_?.stop()
        client_ = nil
    }

    fileprivate func evict(_ target: Bookmark) {
        if let cached = cache.removeValue(forKey: target) {
            log.info("evicting closed connection for \(target.id, privacy: .public)")
            cached.stop()
        }
    }

    private func doConnect(_ target: Bookmark) async throws -> Connection {
        let conn = try client.createConnection()
        try conn.setProductId(id: target.productId)
        try conn.setDeviceId(id: target.deviceId)
        try conn.setPrivateKey(key: try ProfileStore.shared.privateKey(using: client))
        if let sct = target.sct { try conn.setServerConnectToken(sct: sct) }

        try await conn.connectAsync()

        if let fp = target.deviceFingerprint,
           try conn.getDeviceFingerprintHex() != fp {
            conn.stop()
            throw DeviceError.identityChanged
        }
        return conn
    }

    private func handleNetworkPathUpdated(_ path: NWPath) {
        if path.status == .satisfied {
            if !networkAvailable {
                networkAvailable = true
                NotificationCenter.default.post(
                    name: NSNotification.Name(EdgeConnectionManager.eventNameNetworkAvailable),
                    object: nil
                )
            }
        } else if networkAvailable {
            networkAvailable = false
            NotificationCenter.default.post(
                name: NSNotification.Name(EdgeConnectionManager.eventNameNoNetwork),
                object: nil
            )
        }
    }
}
