import Foundation

/// Tells whether a newly read file is the same document as one already in the vault.
///
/// - identity: what makes it the same document, e.g. the passport number, or a lease's address and start.
/// - version: for cards and passports, the issue and expiry dates. A renewal keeps the number but gets new
///   dates, and is a separate document rather than an update.
/// - signature: all important facts. Equal signatures mean the files show the same content.
nonisolated struct DocumentKeys: Equatable, Sendable {
    var identity: String?
    var version: String?
    var signature: String
}

nonisolated enum DocumentMatch: Equatable, Sendable {
    /// Not the same document as any other.
    case none
    /// Another file with the same content: ask which file to keep as the source.
    case duplicate
    /// The same document with different content: ask whether to replace the old one.
    case update
    /// Same number, new dates (a renewal): a separate document, added without asking.
    case newVersion
}

nonisolated enum DocumentIdentity {
    /// The facts that identify a document of this kind. nil when documents of this kind aren't matched.
    static func identityKeys(for kind: DocumentKind) -> [FactKey]? {
        switch kind {
        case .passport, .greenCard, .employmentAuthorization, .visa, .driversLicense, .stateID: [.documentNumber]
        case .lease: [.address, .leaseStartDate]
        case .uscisNotice: [.receiptNumber]
        case .i94: [] // One travel history per person: every I-94 history is the same document.
        case .other, .addedByYou: nil
        }
    }

    static func versionKeys(for kind: DocumentKind) -> [FactKey] {
        switch kind {
        case .passport, .greenCard, .visa, .driversLicense, .stateID: [.issueDate, .expiryDate]
        // EAD cards print "valid from" and "card expires", read as validFrom and validUntil.
        case .employmentAuthorization: [.validFrom, .validUntil]
        default: []
        }
    }

    /// Plain-text keys, before they are fingerprinted for storage. `values` are the document's facts;
    /// `travel` its I-94 rows as "date arrival|departure port".
    static func plainKeys(kind: DocumentKind, values: [FactKey: String], travel: [String] = []) -> DocumentKeys {
        func normalized(_ key: FactKey) -> String? {
            guard let value = values[key], !value.isEmpty else { return nil }
            if key.isDate { return SimpleDate(iso: value)?.iso ?? value }
            return Verifier.compact(value)
        }

        var identity: String?
        if let keys = identityKeys(for: kind) {
            let parts = keys.map { key in normalized(key).map { "\(key.rawValue)=\($0)" } }
            // A document missing its identifying facts can't be matched.
            if !parts.contains(where: { $0 == nil }) {
                identity = ([kind.rawValue] + parts.compactMap { $0 }).joined(separator: "|")
            }
        }
        let versionParts = versionKeys(for: kind).compactMap { key in normalized(key).map { "\(key.rawValue)=\($0)" } }
        let signature = (
            kind.importantKeys.compactMap { key in normalized(key).map { "\(key.rawValue)=\($0)" } }
                + travel.sorted()
        ).joined(separator: "|")
        return DocumentKeys(identity: identity, version: versionParts.isEmpty ? nil : versionParts.joined(separator: "|"), signature: signature)
    }

    static func match(_ new: DocumentKeys, against existing: DocumentKeys) -> DocumentMatch {
        guard let identity = new.identity, identity == existing.identity else { return .none }
        if new.signature == existing.signature { return .duplicate }
        if let version = new.version, let old = existing.version, version != old { return .newVersion }
        return .update
    }
}
