import Foundation
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

    /// Copies to this device's clipboard only, and clears it after 60 seconds.
    static func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(60)]
        )
    }
}
