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
    var error: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func reveal(_ facts: [Fact], reason: String, then: @escaping () -> Void = {}) {
        Task {
            do {
                let context = try await Authenticator.authenticate(reason: reason)
                for fact in facts where fact.isSensitive {
                    values[fact.persistentModelID] = try VaultReader.reveal(fact, context: context)
                    alternates[fact.persistentModelID] = VaultReader.alternate(of: fact, context: context)
                }
                scheduleHide()
                then()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func value(for fact: Fact) -> String? { values[fact.persistentModelID] }

    func alternate(for fact: Fact) -> String? { alternates[fact.persistentModelID] }

    func hide() {
        hideTask?.cancel()
        values = [:]
        alternates = [:]
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            values = [:]
            alternates = [:]
        }
    }
}

