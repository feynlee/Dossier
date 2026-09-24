import Foundation
import SwiftData

/// Confirming a value once confirms it everywhere. When you confirm your name, birth date or place of birth on
/// one document, the same reading on your other documents is confirmed too, and so is the same reading on any
/// document you add later. Only values that are the same person's across documents are shared (not document
/// numbers or dates of issue), and only exact matches (after ignoring case and accents).
enum SharedConfirmation {
    /// The profile value a fact counts toward, when it's the same on every document.
    static func sharedKey(for key: FactKey) -> ProfileKey? {
        ProfileKey.allCases.first { $0.factKey == key }
    }

    /// Whether two readings are the same value.
    nonisolated static func same(_ a: String, _ b: String, for key: ProfileKey) -> Bool {
        let a = Reconciler.normalize(a, for: key), b = Reconciler.normalize(b, for: key)
        return !a.isEmpty && a == b
    }

    /// After you confirm or correct `fact`, confirms the same reading on your other documents. Returns the
    /// titles of the documents that changed.
    @discardableResult
    static func share(from fact: Fact, context: ModelContext) -> [String] {
        guard let key = sharedKey(for: fact.key) else { return [] }
        let confirmed = Reading(fact, key: key)
        guard !confirmed.isEmpty else { return [] }
        var titles: [String] = []
        for other in waiting(for: fact.key, context: context) where other !== fact {
            if resolve(other, with: [confirmed], key: key) {
                titles.append(other.document?.title ?? other.key.label)
            }
        }
        try? context.save()
        return Array(Set(titles)).sorted()
    }

    /// For a document that was just read: confirms readings you already confirmed on another document or
    /// entered yourself in Personal information.
    static func apply(to document: SourceDocument, context: ModelContext) {
        let facts = (try? context.fetch(FetchDescriptor<Fact>())) ?? []
        let overrides = (try? context.fetch(FetchDescriptor<ProfileOverride>())) ?? []
        for fact in document.facts where fact.status == .needsReview {
            guard let key = sharedKey(for: fact.key) else { continue }
            var known = facts
                .filter { $0.keyRaw == fact.keyRaw && $0.check == .userConfirmed && $0.document !== document }
                .map { Reading($0, key: key) }
            if let override = overrides.first(where: { $0.keyRaw == key.rawValue }), !override.isSensitive,
               let value = try? Sealer.shared.open(override.sealedValue) {
                known.append(Reading(value: value, fingerprint: nil))
            }
            resolve(fact, with: known.filter { !$0.isEmpty }, key: key)
        }
    }

    // MARK: Matching

    /// A confirmed value: in the clear for names and dates, a fingerprint for numbers.
    private struct Reading {
        var value: String?
        var fingerprint: Data?

        init(value: String?, fingerprint: Data?) {
            self.value = value
            self.fingerprint = fingerprint
        }

        init(_ fact: Fact, key: ProfileKey) {
            value = fact.isSensitive ? nil : VaultReader.value(of: fact)
            fingerprint = fact.fingerprint
        }

        var isEmpty: Bool { value == nil && fingerprint == nil }
    }

    private static func waiting(for key: FactKey, context: ModelContext) -> [Fact] {
        let raw = key.rawValue
        let needsReview = FactStatus.needsReview.rawValue
        let descriptor = FetchDescriptor<Fact>(predicate: #Predicate { $0.keyRaw == raw && $0.statusRaw == needsReview })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Confirms `fact` if its reading, or its second reading, is one of `known`. Returns whether it did.
    @discardableResult
    private static func resolve(_ fact: Fact, with known: [Reading], key: ProfileKey) -> Bool {
        guard fact.status == .needsReview, !known.isEmpty else { return false }
        if fact.isSensitive {
            // Numbers are compared by fingerprint, without decrypting them.
            guard let fingerprint = fact.fingerprint, known.contains(where: { $0.fingerprint == fingerprint }) else { return false }
            FactEditor.markConfirmed(fact)
            return true
        }
        let values = known.compactMap(\.value)
        if let value = VaultReader.value(of: fact), values.contains(where: { same($0, value, for: key) }) {
            FactEditor.markConfirmed(fact)
            return true
        }
        // Two readings disagreed, and you already confirmed one of them elsewhere: use that one.
        if let alternate = VaultReader.alternate(of: fact, context: nil), values.contains(where: { same($0, alternate, for: key) }),
           let sealed = try? Sealer.shared.seal(alternate, sensitive: false) {
            fact.sealedValue = sealed
            FactEditor.markConfirmed(fact)
            return true
        }
        return false
    }
}
