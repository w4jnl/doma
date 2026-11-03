// DeviceKey is this device's key on the server: an Ed25519 pair made here with CryptoKit, the
// private half kept in the Keychain on this device only, readable after the first unlock so a
// sync in the background can sign. The public half goes up once, at invite acceptance, as
// "ed25519:<base64>"; every request after that is signed with it (docs/design.md, Security).
import CryptoKit
import Foundation
import OSLog
import Security

struct DeviceKey: Sendable, Equatable {
    /// The private key's 32 bytes.
    let raw: Data

    static func make() -> DeviceKey { DeviceKey(raw: Curve25519.Signing.PrivateKey().rawRepresentation) }

    private var key: Curve25519.Signing.PrivateKey? { try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) }

    /// The stored form the server takes: the algorithm, a colon, the 32 public bytes in base64.
    var publicKeyString: String { "ed25519:" + (key?.publicKey.rawRepresentation.base64EncodedString() ?? "") }

    var publicKey: Curve25519.Signing.PublicKey? { key?.publicKey }

    /// A signature over the bytes, 64 bytes.
    func sign(_ message: Data) throws -> Data {
        guard let key else { throw KeyError.invalid }
        return try key.signature(for: message)
    }

    enum KeyError: Error { case invalid, keychain(OSStatus) }

    // MARK: The Keychain

    /// The item's service. Under any test it is a name of its own: on the Mac the test host is
    /// the app itself, with the app's keychain, and a test that made or forgot a key under the
    /// app's name would take the person's key with it.
    static var service: String { UITestHooks.testing ? "nl.w4j.doma.test" : "nl.w4j.doma" }
    static let account = "device-key"

    /// The item, in the data protection keychain: the phone's only one, and on the Mac the one
    /// a signed, sandboxed app can read again after a rebuild. `protected: false` names the
    /// Mac's login keychain, where an ad hoc build, which has no application identifier and so
    /// no data protection keychain, keeps its key instead.
    private static func item(protected: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = protected
        #endif
        return q
    }

    private static var stores: [Bool] {
        #if os(macOS)
        [true, false]
        #else
        [true]
        #endif
    }

    /// The key in the Keychain; nil when this device has none yet. The Mac looks in both of its
    /// keychains, so a key stored by an ad hoc build is still found by a signed one.
    static func load() -> DeviceKey? {
        for protected in stores {
            var q = item(protected: protected)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess, let raw = out as? Data,
               (try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)) != nil {
                return DeviceKey(raw: raw)
            }
            // the status, never the key: which keychain said what, for the log
            Logger(subsystem: "nl.w4j.doma", category: "keychain").notice("device key not loaded from \(protected ? "the data protection keychain" : "the login keychain", privacy: .public): \(status, privacy: .public)")
        }
        return nil
    }

    /// Keeps the key in the Keychain in place of the one there: on this device only, readable
    /// after the first unlock. On the Mac an ad hoc build, refused by the data protection
    /// keychain, falls back to the login keychain.
    func save() throws {
        var last: OSStatus = errSecSuccess
        for protected in Self.stores {
            SecItemDelete(Self.item(protected: protected) as CFDictionary)
            var q = Self.item(protected: protected)
            q[kSecValueData as String] = raw
            if protected {
                q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            last = SecItemAdd(q as CFDictionary, nil)
            Logger(subsystem: "nl.w4j.doma", category: "keychain").notice("device key saved to \(protected ? "the data protection keychain" : "the login keychain", privacy: .public): \(last, privacy: .public)")
            if last == errSecSuccess { return }
            // the data protection keychain wants an application identifier; without one, the
            // login keychain is the Mac's place
            guard last == errSecMissingEntitlement || last == errSecParam else { break }
        }
        throw KeyError.keychain(last)
    }

    /// The key this device uses: the stored one, or a new one stored now.
    static func loadOrMake() throws -> DeviceKey {
        if let k = load() { return k }
        let k = make()
        try k.save()
        return k
    }

    static func forget() {
        for protected in stores {
            SecItemDelete(item(protected: protected) as CFDictionary)
        }
    }
}
