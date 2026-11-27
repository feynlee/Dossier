import Foundation
import FoundationModels
import os

/// Writes the Suggested filing lines for a category you add, with Apple's on-device model. Nothing leaves
/// the iPhone. It sees only the category names and their lines, never your documents.
nonisolated enum CategoryLinesModel {
    private static let logger = Logger(subsystem: "liziyue.Dossier", category: "Library")

    static let instructions = """
        You help organize a personal document library for a household: identity, immigration, health, \
        insurance, money, tax, home, work, education and other papers people keep. For a new category, say \
        which documents go in it and which similar documents belong in another category instead. Write short \
        lines in sentence case that name kinds of documents, such as "Vet records and vaccination certificates". \
        Never name a person, a company or a number.
        """

    /// Up to 4 "What goes here" lines and up to 3 "Not here" lines for a new category. Nil when the model
    /// isn't available or fails.
    static func lines(for name: String, in categories: CategoryList) async -> [FilingLine]? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let others = categories.names.filter { $0 != name && $0 != CategoryList.other }
        let text = DynamicGenerationSchema(type: String.self)
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: "includes", description: "Kinds of documents that go in the new category.",
                  schema: DynamicGenerationSchema(arrayOf: text, minimumElements: 1, maximumElements: 4)),
        ]
        if !others.isEmpty {
            let exclusion = DynamicGenerationSchema(name: "Exclusion", properties: [
                .init(name: "text", description: "Similar documents that belong elsewhere.", schema: text),
                .init(name: "category", description: "Where they go instead.", schema: DynamicGenerationSchema(name: "Other category", anyOf: others)),
            ])
            properties.append(.init(name: "exclusions", description: "Similar documents that belong in another category. Empty when there are none.",
                                    schema: DynamicGenerationSchema(arrayOf: exclusion, minimumElements: 0, maximumElements: 3)))
        }
        let root = DynamicGenerationSchema(name: "CategoryLines", description: "Filing lines for one category", properties: properties)
        do {
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: "\(categories.promptText)\n\nNew category: \(name)\nWhat goes in it, and what similar documents go elsewhere?",
                schema: schema,
                options: GenerationOptions(samplingMode: .greedy)
            )
            let includes = try response.content.value([String].self, forProperty: "includes")
            let exclusions = (try? response.content.value([GeneratedContent].self, forProperty: "exclusions")) ?? []
            var lines = includes.map(clean).filter { !$0.isEmpty }.map { FilingLine(text: $0) }
            for exclusion in exclusions {
                guard let text = try? exclusion.value(String.self, forProperty: "text"),
                      let target = try? exclusion.value(String.self, forProperty: "category"),
                      let resolved = categories.resolve(target), resolved != name else { continue }
                let line = clean(text)
                if !line.isEmpty { lines.append(FilingLine(text: line, pointsTo: resolved)) }
            }
            return lines.isEmpty ? nil : lines
        } catch {
            logger.error("Couldn't write lines for a category: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func clean(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•.")))
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
