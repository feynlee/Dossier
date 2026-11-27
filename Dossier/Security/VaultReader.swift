import Foundation
import Observation
import LocalAuthentication
import UIKit
import UniformTypeIdentifiers

/// Reads sealed values back for display.
enum VaultReader {
    /// The value of a non-sensitive fact.
    static func value(of fact: Fact) -> String? {
        guard !fact.isSensitive else { return nil }
        return try? Sealer.shared.open(fact.sealedValue)
    }

    /// `•••• •• 4821` for a sensitive fact, readable without Face ID.
    static func masked(_ fact: Fact) -> String {
        let hint = fact.sealedHint.flatMap { try? Sealer.shared.open($0) } ?? ""
        return "•••• •• \(hint)"
    }

    static func reveal(_ fact: Fact, context: LAContext) throws -> String {
        try Sealer.shared.openSensitive(fact.sealedValue, context: context)
    }

    /// The full value of a sensitive fact while Dossier is unlocked, with no second Face ID. Nil while
    /// locked, or when the unlock can't open numbers (see `VaultSession`).
    static func revealIfUnlocked(_ fact: Fact) -> String? {
        guard let context = VaultSession.shared.context else { return nil }
        return try? reveal(fact, context: context)
    }

    /// What to show for a sensitive fact: the full value while Dossier is unlocked, else `•••• •• 4821`.
    static func shown(_ fact: Fact) -> String {
        revealIfUnlocked(fact) ?? masked(fact)
    }

    /// Any fact as a card shows it: plain values as they are, numbers in full while Dossier is unlocked.
    static func cardValue(_ fact: Fact) -> String? {
        fact.isSensitive ? shown(fact) : value(of: fact)
    }

    static func alternate(of fact: Fact, context: LAContext?) -> String? {
        guard let sealed = fact.sealedAlternate else { return nil }
        if fact.isSensitive {
            guard let context else { return nil }
            return try? Sealer.shared.openSensitive(sealed, context: context)
        }
        return try? Sealer.shared.open(sealed)
    }

    static func context(of fact: Fact) -> String? {
        fact.sealedContext.flatMap { try? Sealer.shared.open($0) }
    }

    /// A display string for a value: dates as "14 Mar 2029".
    static func display(_ value: String, for key: FactKey) -> String {
        if key.isDate || key == .detail, let date = SimpleDate(iso: value) { return date.display }
        return value
    }

    /// How long a copied number stays on the clipboard.
    static let sensitiveCopyLifetime: TimeInterval = 60

    /// Copies a value. Numbers stay on this device's clipboard only and are cleared after a minute; other
    /// values are an ordinary copy.
    static func copy(_ value: String, sensitive: Bool = true) {
        if sensitive {
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: value]],
                options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(sensitiveCopyLifetime)]
            )
        } else {
            UIPasteboard.general.string = value
        }
    }
}

/// The Face ID check that unlocked Dossier, kept until the app locks again. Every number opens with it, so
/// you look once per unlock and not once per value.
@Observable
final class VaultSession {
    static let shared = VaultSession()

    /// A check that can open numbers. Nil while Dossier is locked, or before the first look when the app
    /// lock is off.
    private(set) var context: LAContext? {
        didSet { Authenticator.unlocked = context }
    }

    /// Keeps a check that just passed, if it can open numbers. An unlock with the passcode can't (the
    /// number key needs Face ID), so the first number then asks for Face ID once, and that check is kept.
    @discardableResult
    func begin(_ context: LAContext) -> Bool {
        // Never show a prompt from here: a check that isn't enough is dropped, not repeated.
        context.interactionNotAllowed = true
        guard Self.canOpenNumbers(with: context) else { return false }
        self.context = context
        return true
    }

    /// Dossier locked: numbers need a new check.
    func end() {
        context?.invalidate()
        context = nil
    }

    /// Seals a short test value to the number key and opens it with the check.
    private static func canOpenNumbers(with context: LAContext) -> Bool {
        guard let probe = try? VaultKeys.shared.sealSensitive(Data("probe".utf8)) else { return false }
        return (try? VaultKeys.shared.openSensitive(probe, context: context)) != nil
    }
}
