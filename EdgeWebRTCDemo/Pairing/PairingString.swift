import Foundation

enum PairingStringError: LocalizedError {
    case empty
    case missingEquals
    case unknownElement(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Pairing string is empty."
        case .missingEquals:
            return "Pairing string element is missing '='"
        case .unknownElement(let key):
            return "Unexpected element in pairing string: \(key)"
        case .missingRequiredField(let field):
            return "Pairing string is missing required field: \(field)"
        }
    }
}

struct PairingDetails {
    var productId: String
    var deviceId: String
    var password: String?
    var sct: String?
    var username: String?
    var deviceFingerprint: String?
}

/// Parses pairing strings of the form `p=...,d=...,u=...,pwd=...,sct=...,fp=...`.
///
/// Accepts `,`, `;` or `:` as element separators. `p` and `d` are required; `u`,
/// `pwd`, `sct` and `fp` are optional.
///
/// - `u`: desired username on the device
/// - `pwd`: pairing password (for `PasswordOpen` / `PasswordInvite`)
/// - `sct`: Server Connect Token (lets the client reach the device via the basestation)
/// - `fp`: expected device public-key fingerprint (used to verify identity at connect)
func parsePairingString(_ raw: String) throws -> PairingDetails {
    let elements = raw
        .components(separatedBy: CharacterSet(charactersIn: ";:,"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !elements.isEmpty else { throw PairingStringError.empty }

    var productId: String?
    var deviceId: String?
    var password: String?
    var sct: String?
    var username: String?
    var fingerprint: String?

    for element in elements {
        guard let equals = element.firstIndex(of: "=") else {
            throw PairingStringError.missingEquals
        }
        let key = String(element[..<equals])
        let value = String(element[element.index(after: equals)...])
        switch key {
        case "p":   productId = value
        case "d":   deviceId = value
        case "pwd": password = value
        case "sct": sct = value
        case "u":   username = value
        case "fp":  fingerprint = value
        default:    throw PairingStringError.unknownElement(key)
        }
    }

    guard let productId else { throw PairingStringError.missingRequiredField("p") }
    guard let deviceId else { throw PairingStringError.missingRequiredField("d") }
    return PairingDetails(
        productId: productId,
        deviceId: deviceId,
        password: password,
        sct: sct,
        username: username,
        deviceFingerprint: fingerprint
    )
}
