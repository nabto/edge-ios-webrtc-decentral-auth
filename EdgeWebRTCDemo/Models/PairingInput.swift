import Foundation

/// Transient pairing data passed from the "Add device" form into the pairing flow.
/// Lives only in memory; `password` is never persisted on disk.
struct PairingInput {
    var productId: String
    var deviceId: String
    var sct: String?
    var password: String?
    var desiredUsername: String?
    /// Optional expected device fingerprint (hex). Carried in pairing strings as `fp=...`;
    /// if present, the pairing flow refuses to pair with a device whose fingerprint differs.
    var expectedFingerprint: String?
}
