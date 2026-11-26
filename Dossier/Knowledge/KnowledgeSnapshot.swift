import Foundation
import LocalAuthentication
import SwiftData

/// Reads the vault into the knowledge layer's plain snapshots. Non-sensitive values are opened with the vault
/// key; sensitive ones stay sealed and only their last four characters and fingerprint come along.
enum KnowledgeSnapshot {
    static func documents(_ sources: [SourceDocument], overrides: [ProfileOverride] = []) -> [KnowledgeDocument] {
        var documents = sources.filter { !$0.isGone && $0.isReady }.map { document($0) }
        if let edited = edits(overrides) { documents.append(edited) }
        return documents
    }

    static func knowledge(in context: ModelContext, today: SimpleDate = .today) throws -> Knowledge {
        let sources = try context.fetch(FetchDescriptor<SourceDocument>())
        let overrides = try context.fetch(FetchDescriptor<ProfileOverride>())
        return KnowledgeBuilder.build(documents(sources, overrides: overrides), today: today)
    }

    static func document(_ source: SourceDocument) -> KnowledgeDocument {
        var fields: [FactKey: KnowledgeValue] = [:]
        var entries: [KnowledgeEntry] = []
        for fact in source.facts.sorted(by: { $0.position < $1.position }) where fact.status != .superseded {
            let read = value(of: fact, in: source)
            if fact.key == .detail {
                entries.append(KnowledgeEntry(section: fact.section, label: fact.label ?? "Detail", value: read, relation: fact.relation, personName: fact.personName))
            } else if fields[fact.key] == nil {
                fields[fact.key] = read
            }
        }
        let travel = source.travel.compactMap { event -> KnowledgeTravelRow? in
            guard let date = (try? Sealer.shared.open(event.sealedDate)).flatMap(SimpleDate.init(iso:)),
                  let port = try? Sealer.shared.open(event.sealedPort) else { return nil }
            return KnowledgeTravelRow(date: date, isArrival: event.isArrival, port: port)
        }
        return KnowledgeDocument(
            id: source.contentHash, kind: source.kind, title: source.title, person: source.placement?.person,
            fields: fields, entries: entries, travel: travel, addedAt: source.ingestedAt
        )
    }

    static func value(of fact: Fact, in source: SourceDocument) -> KnowledgeValue {
        let strength: KnowledgeStrength
        switch (fact.status, fact.check) {
        case (.needsReview, _), (_, .conflict): strength = .doubtful
        case (_, .userConfirmed): strength = .confirmed
        case (_, .mrz), (_, .barcode): strength = .checksum
        case (_, .pageText): strength = .pageText
        default: strength = .model
        }
        return KnowledgeValue(
            text: VaultReader.value(of: fact),
            hint: fact.isSensitive ? fact.sealedHint.flatMap { try? Sealer.shared.open($0) } : nil,
            isSensitive: fact.isSensitive, strength: strength,
            factID: "\(source.contentHash)|\(fact.fieldID)",
            fingerprint: fact.fingerprint?.base64EncodedString()
        )
    }

    /// Values you edited in Personal information: they win over every document.
    static func edits(_ overrides: [ProfileOverride]) -> KnowledgeDocument? {
        var fields: [FactKey: KnowledgeValue] = [:]
        var newest = Date.distantPast
        for override in overrides where !override.isSensitive && !override.isDeleted {
            guard let key = ProfileKey(rawValue: override.keyRaw), let text = try? Sealer.shared.open(override.sealedValue) else { continue }
            let factKey = key == .currentAddress ? FactKey.address : key.factKey
            guard let factKey else { continue }
            fields[factKey] = KnowledgeValue(text: text, strength: .confirmed)
            newest = max(newest, override.editedAt)
        }
        guard !fields.isEmpty else { return nil }
        fields[.issueDate] = KnowledgeValue(text: SimpleDate(utc: newest).iso, strength: .confirmed)
        return KnowledgeDocument(id: "edited-by-you", kind: .addedByYou, title: "Edited by you", person: nil, fields: fields, addedAt: newest)
    }

    /// Opens a sensitive value an answer referred to, after Face ID.
    static func reveal(_ factID: String, in context: ModelContext, authentication: LAContext) throws -> String? {
        let parts = factID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let hash = parts[0], fieldID = parts[1]
        let documents = try context.fetch(FetchDescriptor<SourceDocument>(predicate: #Predicate { $0.contentHash == hash }))
        guard let fact = documents.first?.facts.first(where: { $0.fieldID == fieldID }) else { return nil }
        return try VaultReader.reveal(fact, context: authentication)
    }
}

