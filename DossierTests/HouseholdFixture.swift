import Foundation
@testable import Dossier

/// The made-up household in SampleDocuments/Household, loaded as knowledge snapshots: either exactly as the
/// answer key says (to test the knowledge layer on its own) or as Dossier actually read the files (to test
/// everything end to end).
nonisolated enum HouseholdFixture {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "SampleDocuments/Household", directoryHint: .isDirectory)

    struct Key: Decodable {
        struct Person: Decodable { var name: String; var relation: String; var dob: String }
        struct File: Decodable { var path: String; var variant: String }
        struct Entry: Decodable { var section: String; var label: String; var value: String; var important: Bool }
        struct Detail: Decodable { var person: String; var personName: String; var label: String; var value: String; var important: Bool }
        struct Travel: Decodable { var date: String; var kind: String; var port: String }
        struct Document: Decodable {
            var id: String
            var holder: String
            var kind: String
            var files: [File]
            var fields: [String: String]
            var contents: [Entry]
            var details: [Detail]
            var travel: [Travel]
        }
        var today: String
        var people: [String: Person]
        var documents: [Document]
    }

    struct Question: Decodable {
        var question: String
        var answer: String
        var kind: String
        var person: String
        var sources: [String]
        var sensitive: Bool
        var accept: [String]
    }

    static func key() throws -> Key {
        try JSONDecoder().decode(Key.self, from: Data(contentsOf: folder.appending(path: "answer-key.json")))
    }

    static func questions() throws -> [Question] {
        struct File: Decodable { var questions: [Question] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appending(path: "questions.json"))).questions
    }

    static var today: SimpleDate { SimpleDate(year: 2026, month: 10, day: 31)! }

    static func firstName(_ holder: String, _ key: Key) -> String {
        key.people[holder].map { String($0.name.split(separator: " ")[0]) } ?? holder.capitalized
    }

    static func title(_ document: Key.Document) -> String {
        let file = (document.files[0].path as NSString).deletingPathExtension
        let parts = file.components(separatedBy: " · ")
        return parts.count > 1 && ["Anna", "David", "Emma"].contains(parts[0]) ? parts.dropFirst().joined(separator: " · ") : file
    }

    static let sensitiveLabels = ["social security", "member id", "certificate number", "employer id", "ein"]

    static func sensitive(_ text: String, normalizedFor key: FactKey? = nil) -> KnowledgeValue {
        let normalized = key == .alienNumber ? Reconciler.normalize(text, for: .alienNumber) : KnowledgeText.compact(text)
        return KnowledgeValue(text: nil, hint: String(text.suffix(4)), isSensitive: true, strength: .pageText, factID: text, fingerprint: normalized)
    }

    /// The household exactly as the answer key says.
    static func groundTruth() throws -> [KnowledgeDocument] {
        let key = try key()
        return key.documents.map { document in
            var fields: [FactKey: KnowledgeValue] = [:]
            for (name, value) in document.fields {
                guard let factKey = FactKey(rawValue: name) else { continue }
                fields[factKey] = factKey.isSensitive ? sensitive(value, normalizedFor: factKey) : .plain(value)
            }
            var entries = document.contents.map { entry in
                let isSensitive = sensitiveLabels.contains { entry.label.lowercased().contains($0) }
                return KnowledgeEntry(section: entry.section, label: entry.label, value: isSensitive ? sensitive(entry.value) : .plain(entry.value))
            }
            entries += document.details.map { detail in
                KnowledgeEntry(section: nil, label: detail.label, value: .plain(detail.value), relation: Relation(rawValue: detail.person),
                               personName: detail.personName.isEmpty ? nil : detail.personName)
            }
            let travel = document.travel.compactMap { row in
                SimpleDate(iso: row.date).map { KnowledgeTravelRow(date: $0, isArrival: row.kind == "arrival", port: row.port) }
            }
            return KnowledgeDocument(id: document.id, kind: DocumentKind(rawValue: document.kind) ?? .other, title: title(document),
                                     person: firstName(document.holder, key), fields: fields, entries: entries, travel: travel)
        }
    }

    /// The household as Dossier read it: one reading per document (its clean file when there is one), from the
    /// JSON files `ReadingEvaluation` wrote.
    static func readings(in folder: URL) throws -> [KnowledgeDocument] {
        let key = try key()
        let decoder = JSONDecoder()
        var documents: [KnowledgeDocument] = []
        for document in key.documents {
            let file = document.files.first { $0.variant == "clean" } ?? document.files[0]
            let url = folder.appending(path: (file.path as NSString).deletingPathExtension + ".json")
            guard let data = try? Data(contentsOf: url),
                  let output = try? decoder.decode(ReadingEvaluation.Output.self, from: data), output.error == nil else { continue }
            var fields: [FactKey: KnowledgeValue] = [:]
            for item in output.verified {
                guard let factKey = FactKey(rawValue: item.key) else { continue }
                var value = factKey.isSensitive ? sensitive(item.value, normalizedFor: factKey) : KnowledgeValue.plain(item.value)
                switch (item.status, item.check) {
                case ("needsReview", _), (_, "conflict"): value.strength = .doubtful
                case (_, "mrz"), (_, "barcode"): value.strength = .checksum
                case (_, "pageText"): value.strength = .pageText
                default: value.strength = .model
                }
                fields[factKey] = value
            }
            var entries = output.contents.map { entry in
                KnowledgeEntry(section: entry.section, label: entry.label,
                               value: entry.isNumber == "yes" ? sensitive(entry.value) : .plain(entry.value, strength: entry.confidence == "low" ? .doubtful : .pageText))
            }
            entries += output.details.map { detail in
                KnowledgeEntry(section: nil, label: detail.label, value: .plain(detail.value, strength: detail.confidence == "low" ? .doubtful : .pageText),
                               relation: Relation(rawValue: detail.person), personName: detail.personName.isEmpty ? nil : detail.personName)
            }
            let travel = output.travel.compactMap { row in
                SimpleDate(iso: row.date).map { KnowledgeTravelRow(date: $0, isArrival: row.kind == "arrival", port: row.port) }
            }
            let kind = DocumentKind(rawValue: output.kind ?? "") ?? .other
            documents.append(KnowledgeDocument(id: document.id, kind: kind, title: output.title ?? title(document),
                                               person: firstName(document.holder, key), fields: fields, entries: entries, travel: travel))
        }
        return documents
    }
}
