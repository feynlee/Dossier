import LocalAuthentication
import SwiftData
import SwiftUI

/// A sensitive value: masked as `•••• •• 4821` in a chip until the user reveals it with Face ID. Revealed
/// values mask again after 30 seconds, when the app leaves the foreground, or after a screenshot.
struct MaskedValueView: View {
    let masked: String
    let revealed: String?
    let onReveal: () -> Void

    var body: some View {
        if let revealed {
            Text(revealed)
                .font(.dsFieldValue)
                .textSelection(.enabled)
        } else {
            Button(action: onReveal) {
                HStack(spacing: 8) {
                    Text(masked)
                        .font(.dsFieldValue)
                        .foregroundStyle(.primary)
                    Image(systemName: "faceid")
                        .font(.footnote)
                        .foregroundStyle(Color.dsTint)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(uiColor: .systemGray), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Masked. Reveal with Face ID")
        }
    }
}

/// Session state for revealed sensitive values on one screen.
@Observable
final class RevealState {
    private(set) var values: [PersistentIdentifier: String] = [:]
    /// Second readings of sensitive facts in the review queue, opened with the same Face ID check.
    private(set) var alternates: [PersistentIdentifier: String] = [:]
    /// Whether Face ID was passed on this screen. Numbers and the file stay shown until you leave the screen
    /// or the app.
    private(set) var isUnlocked = false
    /// Face ID is being asked for.
    private(set) var isAuthenticating = false
    var error: String?

    /// Opens every number on the screen with one Face ID. `reusing` is a check that just passed (unlocking
    /// the app): it's tried first without showing anything, and Face ID is asked for only if it doesn't work.
    func reveal(_ facts: [Fact], reason: String, reusing recent: LAContext? = nil, then: @escaping () -> Void = {}) {
        Task {
            if let recent {
                recent.interactionNotAllowed = true
                if open(facts, with: recent) {
                    isUnlocked = true
                    then()
                    return
                }
            }
            isAuthenticating = true
            defer { isAuthenticating = false }
            do {
                let context = try await Authenticator.authenticate(reason: reason)
                for fact in facts where fact.isSensitive {
                    values[fact.persistentModelID] = try VaultReader.reveal(fact, context: context)
                    alternates[fact.persistentModelID] = VaultReader.alternate(of: fact, context: context)
                }
                isUnlocked = true
                then()
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                // You chose not to unlock: the screen stays locked, with its Unlock button.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Opens the numbers with a check that already passed. False if the check can't open them.
    private func open(_ facts: [Fact], with context: LAContext) -> Bool {
        var opened: [PersistentIdentifier: String] = [:]
        for fact in facts where fact.isSensitive {
            guard let value = try? VaultReader.reveal(fact, context: context) else { return false }
            opened[fact.persistentModelID] = value
        }
        values.merge(opened) { $1 }
        for fact in facts where fact.isSensitive {
            alternates[fact.persistentModelID] = VaultReader.alternate(of: fact, context: context)
        }
        return true
    }

    func value(for fact: Fact) -> String? { values[fact.persistentModelID] }

    func alternate(for fact: Fact) -> String? { alternates[fact.persistentModelID] }

    func hide() {
        values = [:]
        alternates = [:]
        isUnlocked = false
    }
}

