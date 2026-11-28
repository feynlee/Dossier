import CryptoKit
import Foundation
import LocalAuthentication

/// Seals and opens fact values. Ordinary values use AES-GCM under the vault key; sensitive values are
/// encrypted to the Secure Enclave key.
nonisolated struct Sealer: Sendable {
    let keys: VaultKeys

    static let shared = Sealer(keys: .shared)

    func seal(_ value: String, sensitive: Bool) throws -> Data {
        let data = Data(value.utf8)
        return sensitive ? try keys.sealSensitive(data) : try Self.seal(data, with: keys.standardKey())
    }

    func open(_ sealed: Data) throws -> String {
        try Self.string(Self.open(sealed, with: keys.standardKey()))
    }

    func openSensitive(_ sealed: Data, context: LAContext) throws -> String {
        try Self.string(keys.openSensitive(sealed, context: context))
    }

    /// A keyed hash of a normalized value, for telling whether two sealed values are the same without
    /// opening them. Useless without this device's vault key.
    func fingerprint(_ normalized: String) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: try keys.standardKey()))
    }

    // MARK: AES-GCM primitives (testable without the Keychain)

    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw VaultKeys.KeyError.decryptionFailed }
        return combined
    }

    static func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    private static func string(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else { throw VaultKeys.KeyError.decryptionFailed }
        return string
    }
}

/// Face ID for revealing sensitive values.
enum Authenticator {
    /// True while a Face ID prompt from inside the app is on screen. The prompt makes the app inactive for a
    /// moment; that isn't leaving the app, so the privacy cover stays hidden and revealed values stay shown.
    @MainActor private(set) static var isPrompting = false
    /// The check that unlocked Dossier, set by the app's unlock session. Nil in the extensions.
    @MainActor static var unlocked: LAContext?
    enum AuthError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case .unavailable(let message) = self { return message }
            return nil
        }
    }

    /// Returns a context that has passed Face ID, for handing to the Secure Enclave.
    /// While Dossier is unlocked, the check that unlocked it is used again, with no second prompt.
    /// `fresh` always asks, for a screen that wants its own check.
    static func authenticate(reason: String, fresh: Bool = false) async throws -> LAContext {
        if !fresh, let unlocked { return unlocked }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        #if targetEnvironment(simulator)
        let policy = LAPolicy.deviceOwnerAuthentication
        #else
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        #endif
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw AuthError.unavailable(error?.localizedDescription ?? "Face ID isn’t set up on this iPhone.")
        }
        isPrompting = true
        defer { isPrompting = false }
        try await context.evaluatePolicy(policy, localizedReason: reason)
        return context
    }
}
