import Foundation
import LocalAuthentication
import SwiftData

/// Your personal information, compiled from every document plus any values you edited.
struct Profile {
    struct Entry: Identifiable {
        var id: ProfileKey { key }
        var key: ProfileKey
        var status: ReconciledEntry.Status
        /// Set when you edited this value; it wins over the documents.
        var override: ProfileOverride?
        /// The fact the value comes from (for sensitive values, the one to reveal).
        var fact: Fact?
        /// The value in the clear, for non-sensitive keys.
        var value: String?
        /// Where it comes from, for the subtitle.
        var sources: [String]
        /// For a conflict: each distinct reading with the documents that show it.
        var options: [Option]

        var needsAttention: Bool { override == nil && (status == .conflict) }
    }

    struct Option: Identifiable {
        var id: String { fact.persistentModelID.hashValue.description }
        var fact: Fact
        var value: String?
        var sources: [String]
    }

    var entries: [Entry]

    func entry(_ key: ProfileKey) -> Entry? { entries.first { $0.key == key } }

    var conflicts: [Entry] { entries.filter(\.needsAttention) }

    // MARK: Building

    static func build(documents: [SourceDocument], overrides: [ProfileOverride], timeline: LifeTimeline? = nil) -> Profile {
        // Built in a task, so a document may have been removed since: skip those. Family members' documents
        // are theirs, not yours: only the owner's, the household's and unsorted ones count.
        let owner = LibraryGroups.owner(documents.compactMap(\.placement))
        let ready = documents.filter { document in
            guard !document.isGone, document.isReady else { return false }
            guard let person = document.placement?.person, let owner else { return true }
            return person == owner || person == LibraryPlacement.household
        }
        let overrides = overrides.filter { !$0.isDeleted && $0.modelContext != nil }
        let overridesByKey = Dictionary(overrides.map { ($0.keyRaw, $0) }, uniquingKeysWith: { first, _ in first })
        var factsByID: [String: Fact] = [:]
        var entries: [Entry] = []

        for key in ProfileKey.allCases {
            let override = overridesByKey[key.rawValue]
            var entry = Entry(key: key, status: .missing, override: override, fact: nil, value: nil, sources: [], options: [])

            switch key {
            case .passportNumber, .licenceNumber:
                // The current document's number: newest expiry first.
                let document = ready
                    .filter { key.sources.contains($0.kind) && $0.fact(.documentNumber) != nil }
                    .max { ($0.expiryDate ?? .distantPast) < ($1.expiryDate ?? .distantPast) }
                if let document, let fact = document.fact(.documentNumber) {
                    entry.fact = fact
                    entry.status = fact.status == .needsReview ? .uncertain : .single
                    entry.sources = [document.title]
                }
            case .currentAddress:
                let timeline = timeline ?? TimelineLoader.timeline(from: ready)
                if let home = timeline.home(on: timeline.today) ?? timeline.homes.last {
                    entry.value = home.address
                    entry.status = home.needsReview ? .uncertain : .single
                    entry.sources = [home.source]
                }
            default:
                guard let factKey = key.factKey else { break }
                var candidates: [ProfileCandidate] = []
                for document in ready {
                    guard let priority = key.sources.firstIndex(of: document.kind), let fact = document.fact(factKey) else { continue }
                    let id = "\(document.contentHash)#\(factKey.rawValue)"
                    factsByID[id] = fact
                    let value = fact.isSensitive ? nil : VaultReader.value(of: fact)
                    let matchKey: String
                    if fact.isSensitive {
                        // Without a fingerprint (facts read by earlier versions) the value can't be compared.
                        guard let fingerprint = fact.fingerprint else { continue }
                        matchKey = fingerprint.base64EncodedString()
                    } else {
                        guard let value else { continue }
                        matchKey = Reconciler.normalize(value, for: key)
                    }
                    candidates.append(ProfileCandidate(
                        id: id, matchKey: matchKey, value: value ?? "", sourceTitle: document.title, priority: priority,
                        isChecked: [.mrz, .barcode, .userConfirmed].contains(fact.check),
                        isCertain: fact.status != .needsReview
                    ))
                }
                let result = Reconciler.reconcile(key, candidates: candidates)
                entry.status = result.status
                if let chosen = result.chosen {
                    entry.fact = factsByID[chosen.id]
                    entry.value = key.isSensitive ? nil : chosen.value
                    entry.sources = result.groups.first?.map(\.sourceTitle) ?? []
                }
                if result.status == .conflict {
                    entry.options = result.groups.compactMap { group in
                        factsByID[group[0].id].map { Option(fact: $0, value: key.isSensitive ? nil : group[0].value, sources: group.map(\.sourceTitle)) }
                    }
                }
            }

            if let override, !override.isSensitive {
                entry.value = try? Sealer.shared.open(override.sealedValue)
            }
            entries.append(entry)
        }
        return Profile(entries: entries)
    }

    // MARK: Values

    /// The value for display or for filling a form. Sensitive values need a context that passed Face ID.
    func value(_ key: ProfileKey, context: LAContext?) -> String? {
        guard let entry = entry(key) else { return nil }
        if let override = entry.override {
            if override.isSensitive {
                guard let context else { return nil }
                return try? Sealer.shared.openSensitive(override.sealedValue, context: context)
            }
            return entry.value
        }
        if key.isSensitive {
            guard let context, let fact = entry.fact else { return nil }
            return try? VaultReader.reveal(fact, context: context)
        }
        return entry.value
    }

    /// `•••• •• 4821` for a sensitive value.
    func masked(_ key: ProfileKey) -> String? {
        guard let entry = entry(key) else { return nil }
        if let override = entry.override, override.isSensitive { return "•••• •• ••••" }
        return entry.fact.map { VaultReader.masked($0) }
    }

    // MARK: Editing

    /// Saves your value for a key, replacing what the documents say.
    static func setOverride(_ value: String, for key: ProfileKey, in context: ModelContext) throws {
        let normalized = key.isDate ? (SimpleDate(iso: value)?.iso ?? value) : value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sealed = try Sealer.shared.seal(normalized, sensitive: key.isSensitive)
        let existing = try context.fetch(FetchDescriptor<ProfileOverride>()).first { $0.keyRaw == key.rawValue }
        if let existing {
            existing.sealedValue = sealed
            existing.isSensitive = key.isSensitive
            existing.editedAt = .now
        } else {
            context.insert(ProfileOverride(key: key.rawValue, sealedValue: sealed, isSensitive: key.isSensitive))
        }
        try context.save()
    }

    /// Goes back to what the documents say.
    static func removeOverride(for key: ProfileKey, in context: ModelContext) throws {
        for override in try context.fetch(FetchDescriptor<ProfileOverride>()) where override.keyRaw == key.rawValue {
            context.delete(override)
        }
        try context.save()
    }
}

extension ReconciledEntry.Status {
    /// "3 documents agree", "From Passport", "Documents disagree"…
    func summary(sources: [String], edited: Bool) -> String {
        if edited { return "Edited by you" }
        switch self {
        case .agreed(let count): return "\(count) documents agree"
        case .single: return sources.first.map { "From \($0)" } ?? ""
        case .conflict: return "Documents disagree"
        case .uncertain: return "Not sure yet · in Review"
        case .missing: return "Not in your documents"
        }
    }
}
