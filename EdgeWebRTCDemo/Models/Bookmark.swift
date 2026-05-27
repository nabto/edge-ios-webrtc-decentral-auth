import Foundation

final class Bookmark: Equatable, Hashable, CustomStringConvertible, Codable, Identifiable {
    let deviceId: String
    let productId: String
    var timeAdded: Date?
    var sct: String?
    var name: String = "Anonymous Device"
    var modelName: String?
    var role: String?
    var deviceFingerprint: String?
    var tracks: [String]?

    var id: String { "\(productId).\(deviceId)" }

    init(
        deviceId: String,
        productId: String,
        creationTime: Date? = nil,
        sct: String? = nil,
        name: String? = nil,
        modelName: String? = nil,
        role: String? = nil,
        tracks: [String]? = nil
    ) {
        self.deviceId = deviceId
        self.productId = productId
        self.timeAdded = creationTime
        self.sct = sct
        if let name { self.name = name }
        self.modelName = modelName
        self.role = role
        self.tracks = tracks
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(deviceId)
        hasher.combine(productId)
    }

    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        lhs.deviceId == rhs.deviceId && lhs.productId == rhs.productId
    }

    var description: String {
        "Bookmark(productId: \(productId), deviceId: \(deviceId), name: \(name), role: \(role ?? "nil"))"
    }
}
