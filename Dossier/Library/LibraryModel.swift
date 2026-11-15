import Foundation
import FoundationModels
import os

@Generable(description: "Where one document goes in a personal document library, and what it's called")
nonisolated struct PlacementReading {
    @Guide(description: "The top-level category. Use an existing one when it fits; otherwise one of the starter categories, or a new name of one or two words.")
    var category: String

    @Guide(description: "The folder inside the category, named for the kind of document in the plural, such as \"I-20s\" or \"Vaccination records\". Reuse an existing folder when the document is the same kind.")
    var folder: String

    @Guide(description: "What the document is, in a few words of sentence case, such as \"I-20\", \"Vaccination record\" or \"W-2\".")
    var type: String

    @Guide(description: "One short detail that tells it apart from others of its type, such as a school, an employer or a tax year. Never a number, ID or account. Empty when nothing fits.")
    var detail: String
}

@Generable(description: "A new top-level layout for a personal document library")
nonisolated struct LayoutReading {
    @Guide(description: "One entry for every folder listed, in the same order.")
    var folders: [FolderMoveReading]
}

@Generable(description: "Where one existing folder goes in the new layout")
nonisolated struct FolderMoveReading {
    @Guide(description: "The folder's number from the list.")
    var number: Int

    @Guide(description: "Its category in the new layout: one or two words.")
    var category: String

    @Guide(description: "Its name in the new layout. Keep the current name unless merging it with another folder of the same kind.")
    var folder: String
}

@Generable(description: "The real people behind a list of people found in a household's documents")
nonisolated struct PeopleReading {
    @Guide(description: "One entry for each real person. Every listed number goes in exactly one entry.")
    var people: [PersonReading]
}

@Generable(description: "One real person")
nonisolated struct PersonReading {
    @Guide(description: "The numbers of the listed people who are this one person.")
    var numbers: [Int]

    @Guide(description: "The first name to file their documents under, in Latin letters, without the family name. A Chinese given name in pinyin is one name: Zi Yue is \"Ziyue\".")
    var firstName: String
}

/// Asks Apple's on-device model where documents go. It sees each document's kind, title and type of dates,
/// and the folders already in use, never the facts read from it.
actor LibraryModel {
    private let model = SystemLanguageModel.default
    private let logger = Logger(subsystem: "liziyue.Dossier", category: "Library")

    nonisolated var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static let instructions = """
        You organize a personal document library: identity, immigration, housing, health, tax, education and \
        work documents for a household. Folders go Category › Folder. Keep the top level short, at most \
        \(LibraryPlanner.maxCategories) categories of one or two words, following this pattern: \
        \(LibraryNaming.starterCategories.joined(separator: ", ")). Reuse existing categories and folders \
        whenever a document fits them, so documents of the same kind end up together. Never put numbers, IDs \
        or account details in any name.
        """

    func place(title: String, kind: String, existing: [FolderKey]) async -> ModelPlacement? {
        guard model.isAvailable else { return nil }
        let folders = existing.isEmpty ? "None yet." : existing.map { "- \($0.category) › \($0.folder)" }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: "Existing folders:\n\(folders)\n\nDocument: \"\(title)\" (\(kind)). Where does it go?",
                generating: PlacementReading.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            let reading = response.content
            let detail = reading.detail.trimmingCharacters(in: .whitespaces)
            return ModelPlacement(category: reading.category, folder: reading.folder, type: reading.type, detail: detail.isEmpty ? nil : detail)
        } catch {
            logger.error("Couldn't place a document: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static let peopleInstructions = """
        You work out who is who in a household's documents. The same person's name is often written \
        differently on different documents: in Chinese characters or in pinyin, with or without spaces between \
        the syllables of one name, with or without middle names, in capitals or not. Decide which of the listed \
        people are really the same person, from their names, family names, birth dates and documents. People \
        with different birth dates are never the same person. When you are not sure, keep them apart. For each \
        person, give the first name their documents agree on, as written on their identity documents.
        """

    /// The model's review of the people the rules found: which are the same person, and their first names.
    /// Runs on the device only; nothing leaves it.
    func people(_ groups: [PersonGroup]) async -> [PersonDecision]? {
        guard model.isAvailable, groups.count > 1 else { return nil }
        let list = groups.enumerated().map { index, group in
            var lines = ["\(index + 1). Given names as printed: \(Set(group.printedNames).sorted().map { "\"\($0)\"" }.joined(separator: ", "))"]
            if let surname = group.surname { lines.append("   Family name: \(surname)") }
            if !group.datesOfBirth.isEmpty { lines.append("   Born: \(group.datesOfBirth.map(\.iso).sorted().joined(separator: ", "))") }
            let documents = zip(group.kinds, group.titles).map { kind, title in kind == .other ? title : kind.displayName }
            lines.append("   Documents: \(Array(Set(documents)).sorted().prefix(8).joined(separator: "; "))")
            lines.append("   Filed as: \(group.firstName)")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: Self.peopleInstructions)
        do {
            let response = try await session.respond(
                to: "People found in the documents:\n\(list)\n\nWho is the same person, and what is each person's first name?",
                generating: PeopleReading.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            return response.content.people.map { PersonDecision(numbers: $0.numbers, firstName: $0.firstName) }
        } catch {
            logger.error("Couldn't review the people: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A new layout for folders that have outgrown the current one. Returns the folders that move.
    func layout(_ folders: [LibraryPlanner.FolderSummary]) async -> [FolderKey: FolderKey] {
        guard model.isAvailable, !folders.isEmpty else { return [:] }
        let list = folders.enumerated().map { index, summary in
            "\(index + 1). \(summary.key.category) › \(summary.key.folder): \(summary.count) documents, such as \(summary.examples.joined(separator: "; "))"
        }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: "The library's folders:\n\(list)\n\nRegroup them under a short top level that makes these documents easy to find.",
                generating: LayoutReading.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            var moves: [FolderKey: FolderKey] = [:]
            for move in response.content.folders where folders.indices.contains(move.number - 1) {
                moves[folders[move.number - 1].key] = FolderKey(category: move.category, folder: move.folder)
            }
            return LibraryPlanner.validated(moves, for: folders)
        } catch {
            logger.error("Couldn't lay out the library: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }
}
