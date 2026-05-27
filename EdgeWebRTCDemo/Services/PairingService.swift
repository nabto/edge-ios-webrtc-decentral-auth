import Foundation
import OSLog
import NabtoEdgeClient
import NabtoEdgeIamUtil

private let log = Logger(subsystem: "com.nabto.EdgeWebRTCDemo", category: "Pairing")

/// Show only the first 2 characters of a secret, padded with `...`. Empty / nil
/// secrets are shown as `<nil>` / `<empty>` so it's obvious when nothing was sent.
private func redact(_ secret: String?) -> String {
    guard let secret else { return "<nil>" }
    if secret.isEmpty { return "<empty>" }
    return "\(secret.prefix(2))..."
}

enum PairingError: LocalizedError {
    case deviceNotOpenForPairing
    case unsupportedMode
    case passwordRequired
    case usernameTaken
    case authenticationFailed
    case blockedByDeviceConfiguration
    case fingerprintMismatch(expected: String, actual: String)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .deviceNotOpenForPairing:
            return "Device is not open for pairing. Contact the owner, or factory reset to recover."
        case .unsupportedMode:
            return "This app only supports LocalInitial, LocalOpen, PasswordOpen and PasswordInvite pairing modes."
        case .passwordRequired:
            return "This device requires a password for pairing."
        case .usernameTaken:
            return "That username is already in use on the device."
        case .authenticationFailed:
            return "Pairing password not valid for this device."
        case .blockedByDeviceConfiguration:
            return "The device IAM configuration does not permit pairing."
        case .fingerprintMismatch(let expected, let actual):
            return "Device identity does not match the pairing string. Expected \(expected.prefix(12))..., got \(actual.prefix(12))..."
        case .unknown(let error):
            return "Pairing failed: \(error)"
        }
    }
}

enum PairingService {

    /// Pair with `input`, persist the resulting bookmark in `store`, return it.
    ///
    /// Auto-selects the IAM pairing mode based on what the device advertises and what
    /// credentials are present in `input`:
    ///
    /// - `LocalInitial` if available (fresh device, bootstrap admin).
    /// - else `LocalOpen` (open device on LAN, no password).
    /// - else `PasswordOpen` (open device, shared password from pairing string).
    /// - else `PasswordInvite` (admin-issued per-user password).
    static func pair(input: PairingInput, into store: BookmarkStore) async throws -> Bookmark {
        log.info("pair() input productId=\(input.productId, privacy: .public) deviceId=\(input.deviceId, privacy: .public) sct=\(input.sct ?? "<nil>", privacy: .public) desiredUsername=\(input.desiredUsername ?? "<nil>", privacy: .public) password=\(redact(input.password), privacy: .public) expectedFingerprint=\(input.expectedFingerprint ?? "<nil>", privacy: .public)")

        let bookmark = Bookmark(
            deviceId: input.deviceId,
            productId: input.productId,
            sct: input.sct
        )

        log.info("makeUnpairedConnection productId=\(input.productId, privacy: .public) deviceId=\(input.deviceId, privacy: .public) sct=\(input.sct ?? "<nil>", privacy: .public)")
        let connection = try await EdgeConnectionManager.shared.makeUnpairedConnection(
            productId: input.productId,
            deviceId: input.deviceId,
            sct: input.sct
        )

        try await Self.runBlocking {
            try connection.connect()
        }
        log.info("connection.connect() ok")

        do {
            if let expected = input.expectedFingerprint {
                let actual = try connection.getDeviceFingerprintHex()
                log.info("fingerprint check expected=\(expected, privacy: .public) actual=\(actual, privacy: .public)")
                guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
                    throw PairingError.fingerprintMismatch(expected: expected, actual: actual)
                }
            }
            try await runPairing(connection: connection, input: input)
            try fillBookmarkFromConnection(bookmark, connection: connection)
        } catch {
            log.error("pair() failed: \(String(describing: error), privacy: .public)")
            connection.stop()
            throw mapError(error)
        }

        connection.stop()
        try store.add(bookmark)
        return bookmark
    }

    // MARK: - Mode selection

    private static func runPairing(connection: Connection, input: PairingInput) async throws {
        let modes = try await runBlocking { try IamUtil.getAvailablePairingModes(connection: connection) }
        log.info("device offers pairing modes: \(modes.map { "\($0)" }.joined(separator: ", "), privacy: .public)")
        if modes.isEmpty { throw PairingError.deviceNotOpenForPairing }

        let rawUsername = input.desiredUsername ?? defaultUsername()
        let username = sanitizedUsername(rawUsername)
        let displayName = rawUsername
        log.info("username raw=\(rawUsername, privacy: .public) sanitized=\(username, privacy: .public) displayName=\(displayName, privacy: .public)")

        if modes.contains(.LocalInitial) {
            log.info("calling IamUtil.pairLocalInitial(connection)")
            try await runBlocking { try IamUtil.pairLocalInitial(connection: connection) }
        } else if modes.contains(.LocalOpen) {
            log.info("calling IamUtil.pairLocalOpen(connection, desiredUsername=\(username, privacy: .public))")
            try await runBlocking {
                try IamUtil.pairLocalOpen(connection: connection, desiredUsername: username)
            }
        } else if modes.contains(.PasswordOpen) {
            guard let password = input.password else { throw PairingError.passwordRequired }
            log.info("calling IamUtil.pairPasswordOpen(connection, desiredUsername=\(username, privacy: .public), password=\(redact(password), privacy: .public))")
            try await runBlocking {
                try IamUtil.pairPasswordOpen(
                    connection: connection,
                    desiredUsername: username,
                    password: password
                )
            }
        } else if modes.contains(.PasswordInvite) {
            guard let password = input.password else { throw PairingError.passwordRequired }
            log.info("calling IamUtil.pairPasswordInvite(connection, username=\(username, privacy: .public), password=\(redact(password), privacy: .public))")
            try await runBlocking {
                try IamUtil.pairPasswordInvite(
                    connection: connection,
                    username: username,
                    password: password
                )
            }
        } else {
            throw PairingError.unsupportedMode
        }
        log.info("pairing call returned ok")

        // Best-effort: ignore failures (some devices block display-name updates).
        try? await runBlocking {
            try IamUtil.updateUserDisplayName(
                connection: connection,
                username: username,
                displayName: displayName
            )
        }
    }

    // MARK: - Post-pairing enrichment

    private static func fillBookmarkFromConnection(_ bookmark: Bookmark, connection: Connection) throws {
        let user = try IamUtil.getCurrentUser(connection: connection)
        bookmark.role = user.Role
        if let sct = user.Sct { bookmark.sct = sct }
        let details = try IamUtil.getDeviceDetails(connection: connection)
        if let appName = details.AppName { bookmark.name = appName }
        bookmark.deviceFingerprint = try connection.getDeviceFingerprintHex()
    }

    // MARK: - Helpers

    /// Username must be lower-case [a-z0-9._-]; mirror `ProfileTools.convertToValidUsername`.
    static func sanitizedUsername(_ raw: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        let lowered = raw.lowercased()
        let filtered = String(lowered.unicodeScalars.map {
            allowed.contains(Character($0)) ? Character($0) : "-"
        })
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return trimmed.isEmpty ? "user" : String(trimmed.prefix(64))
    }

    private static func defaultUsername() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "ios-client"
        #endif
    }

    /// Bridge IamUtil's blocking sync API to async/await.
    private static func runBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func mapError(_ error: Error) -> Error {
        if let pairing = error as? PairingError { return pairing }
        if let iam = error as? IamError {
            switch iam {
            case .USERNAME_EXISTS: return PairingError.usernameTaken
            case .AUTHENTICATION_ERROR: return PairingError.authenticationFailed
            case .BLOCKED_BY_DEVICE_CONFIGURATION: return PairingError.blockedByDeviceConfiguration
            default: break
            }
        }
        return PairingError.unknown(error)
    }
}

#if canImport(UIKit)
import UIKit
#endif
