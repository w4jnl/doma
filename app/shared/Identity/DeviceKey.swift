// DeviceKey is this device's key on the server: an Ed25519 pair made here with CryptoKit, the
// private half kept in the Keychain on this device only, readable after the first unlock so a
// sync in the background can sign. The public half goes up once, at invite acceptance, as
// "ed25519:<base64>"; every request after that is signed with it (docs/design.md, Security).
import CryptoKit
import Foundation
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

    static let service = "nl.w4j.doma"
    static let account = "device-key"

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// The key in the Keychain; nil when this device has none yet.
    static func load() -> DeviceKey? {
        var q = item
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let raw = out as? Data,
              (try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)) != nil
        else { return nil }
        return DeviceKey(raw: raw)
    }

    /// Keeps the key in the Keychain in place of the one there: on this device only, readable
    /// after the first unlock.
    func save() throws {
        SecItemDelete(Self.item as CFDictionary)
        var q = Self.item
        q[kSecValueData as String] = raw
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }

    /// The key this device uses: the stored one, or a new one stored now.
    static func loadOrMake() throws -> DeviceKey {
        if let k = load() { return k }
        let k = make()
        try k.save()
        return k
    }

    static func forget() {
        SecItemDelete(item as CFDictionary)
    }
}
