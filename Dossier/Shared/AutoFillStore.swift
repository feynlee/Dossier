import Foundation
import Security

/// The values AutoFill offers in other apps, kept in the Keychain that Dossier shares with its AutoFill
/// extension (and with nothing else). Every value stays sealed exactly as in the vault: ordinary ones need
/// the vault key, numbers need Face ID. Dossier refreshes the list whenever your documents change.
nonisolated enum AutoFillStore {
    struct Snapshot: Codable, Sendable {
        var entries: [FormEntry]
        var updated: Date
    }

    private static let service = "liziyue.Dossier.autofill"
    private static let account = "catalog"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ entries: [FormEntry]) {
        guard let data = try? JSONEncoder().encode(Snapshot(entries: entries, updated: .now)) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func load() -> Snapshot? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
