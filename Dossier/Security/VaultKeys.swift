import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Holds the two vault keys, both of which stay in this device's Keychain and never sync:
/// - a 256-bit AES key for ordinary facts, readable whenever the device is unlocked;
/// - a P-256 key in the Secure Enclave for sensitive facts. Anyone can encrypt to its public key, so imports
///   need no prompt, but decrypting needs Face ID with the currently enrolled faces.
nonisolated final class VaultKeys: Sendable {
    enum KeyError: LocalizedError {
        case keychain(OSStatus)
        case secureEnclave(String)
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .keychain(let status): "The Keychain returned error \(status)."
            case .secureEnclave(let message): message
            case .decryptionFailed: "This value can’t be opened. If you re-enrolled Face ID, re-read your documents in Settings."
            }
        }
    }

    static let shared = VaultKeys()

    private let service = "liziyue.Dossier.vault"
    private let standardAccount = "standard-key"
    private let sensitiveTag = Data("liziyue.Dossier.sensitive-key".utf8)
    private let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    // MARK: Standard key

    func standardKey() throws -> SymmetricKey {
        if let data = try readStandardKey() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: standardAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        return key
    }

    private func readStandardKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: standardAccount,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        return result as? Data
    }

    // MARK: Sensitive key

    /// Encrypts to the sensitive key's public half. Never prompts.
    func sealSensitive(_ plaintext: Data) throws -> Data {
        let privateKey = try sensitivePrivateKey(context: nil, createIfMissing: true)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw KeyError.secureEnclave("The vault key has no public key.") }
        var error: Unmanaged<CFError>?
        guard let sealed = SecKeyCreateEncryptedData(publicKey, algorithm, plaintext as CFData, &error) as Data? else {
            throw KeyError.secureEnclave(error?.takeRetainedValue().localizedDescription ?? "Encryption failed.")
        }
        return sealed
    }

    /// Decrypts with the private half. Pass an `LAContext` that has already passed Face ID so the Secure
    /// Enclave doesn't prompt a second time.
    func openSensitive(_ sealed: Data, context: LAContext) throws -> Data {
        let privateKey = try sensitivePrivateKey(context: context, createIfMissing: false)
        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(privateKey, algorithm, sealed as CFData, &error) as Data? else {
            throw KeyError.decryptionFailed
        }
        return plaintext
    }

    private func sensitivePrivateKey(context: LAContext?, createIfMissing: Bool) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: sensitiveTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result { return result as! SecKey }
        guard status == errSecItemNotFound, createIfMissing else { throw KeyError.keychain(status) }
        return try createSensitiveKey()
    }

    private func createSensitiveKey() throws -> SecKey {
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: sensitiveTag,
        ]
        #if targetEnvironment(simulator)
        // The Simulator has no Secure Enclave. Use a software key; the app still requires Face ID before
        // it asks for a decryption, but the Keychain itself doesn't enforce it here.
        privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &acError
        ) else {
            throw KeyError.secureEnclave(acError?.takeRetainedValue().localizedDescription ?? "Access control failed.")
        }
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        privateAttributes[kSecAttrAccessControl as String] = access
        #endif
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw KeyError.secureEnclave(error?.takeRetainedValue().localizedDescription ?? "The vault key couldn’t be created.")
        }
        return key
    }

    // MARK: Reset

    /// Deletes both keys, which makes every sealed value unreadable. Used by "Delete all extracted data".
    func destroyAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: sensitiveTag] as CFDictionary)
    }
}
