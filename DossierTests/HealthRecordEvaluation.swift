import Foundation
import SwiftData
import Testing
@testable import Dossier

/// Reads the made-up health summary (SampleDocuments/Health) with the app's real pipeline, saves it exactly as
/// the app does (facts verified against the page and sealed in a vault store, here in memory), then asks Siri's
/// questions through the same path as "Ask Dossier". Writes one report per file; asserts only that the blood
/// type was read, saved and answered.
///
///     TEST_RUNNER_DOSSIER_HEALTH_DIR=/path/to/SampleDocuments/Health \
///     TEST_RUNNER_DOSSIER_HEALTH_ENGINE=device|pcc \
///     xcodebuild test -scheme Dossier -only-testing:DossierTests/HealthRecordEvaluation …
nonisolated enum HealthEvaluationEnvironment {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["DOSSIER_HEALTH_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

@MainActor
@Suite(.enabled(if: HealthEvaluationEnvironment.folder != nil), .serialized)
struct HealthRecordEvaluation {
    struct Key: Decodable {
        struct Question: Decodable { var question: String; var accept: [String] }
        var questions: [Question]
    }

    struct Report: Encodable {
        struct Row: Encodable { var section: String?; var label: String; var value: String }
        struct Answer: Encodable {
            var vault: String
            var strategy: String
            var question: String
            var answer: String
            var right: Bool
            var method: String
            var note: String?
            var seconds: Double
        }
        var file: String
        var engine = ""
        var kind = ""
        var title = ""
        var read: [Row] = []
        var saved: [Row] = []
        var answers: [Answer] = []
        var error: String?
    }

    @Test(.timeLimit(.minutes(30)))
    func readSaveAndAsk() async throws {
        let folder = try #require(HealthEvaluationEnvironment.folder)
        let environment = ProcessInfo.processInfo.environment
        let usePrivateCloud = environment["DOSSIER_HEALTH_ENGINE"] == "pcc"
        let output = folder.appending(path: "results", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let key = try JSONDecoder().decode(Key.self, from: Data(contentsOf: folder.appending(path: "answer-key.json")))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["pdf", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let container = try ModelContainer(
            for: SourceDocument.self, Fact.self, TravelEvent.self, ProfileOverride.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let coordinator = ImportCoordinator()
        let household = try HouseholdFixture.groundTruth()
        var bloodTypeAnswered = 0

        for file in files {
            var report = Report(file: file.lastPathComponent)
            do {
                let pages = try await PageReader.read(try Data(contentsOf: file), fileName: file.lastPathComponent)
                let (reading, engine) = try await DocumentExtractor().extract(pages: pages, preferPrivateCloud: usePrivateCloud, request: .current)
                report.engine = engine.rawValue
                report.kind = reading.kind
                report.title = reading.title
                report.read = reading.contents.map { .init(section: $0.section, label: $0.label, value: $0.value) }
                    + reading.details.map { .init(section: nil, label: "\($0.person) · \($0.label)", value: $0.value) }

                let document = SourceDocument(contentHash: SourceDocument.pendingPrefix + file.lastPathComponent, fileName: file.lastPathComponent,
                                              kind: .other, title: file.lastPathComponent, engine: engine, pageCount: pages.count)
                context.insert(document)
                try coordinator.save(reading, engine: engine, pages: pages, hash: UUID().uuidString, info: nil, into: document, context: context)
                let saved = KnowledgeSnapshot.document(document)
                report.saved = saved.entries.map { .init(section: $0.section, label: $0.label, value: $0.value.text ?? "[sealed, ends \($0.value.hint ?? "?")]") }
                    + saved.fields.map { .init(section: "field", label: $0.key.rawValue, value: $0.value.text ?? "[sealed]") }

                // The vaults Siri may see: the record alone, not yet placed in the library; and filed under
                // Anna in a full vault.
                document.placement = nil
                let alone = try KnowledgeSnapshot.knowledge(in: context, today: HouseholdFixture.today)
                document.placement = LibraryPlacement(person: "Anna", category: "Health", folder: "Records", name: "Anna · Health summary")
                let mine = KnowledgeSnapshot.document(document)
                let full = KnowledgeBuilder.build(household + [mine], today: HouseholdFixture.today)

                for (vault, knowledge) in [("alone", alone), ("full", full)] {
                    for strategy in [AnswerStrategy.rulesOnly, .automatic] {
                        for question in key.questions {
                            let started = Date.now
                            let answer = await KnowledgeService.answer(question.question, knowledge: knowledge, strategy: strategy)
                            let right = answer.found && question.accept.contains { answer.text.localizedCaseInsensitiveContains($0) }
                            if right, question.question.contains("blood") { bloodTypeAnswered += 1 }
                            report.answers.append(.init(vault: vault, strategy: strategy.rawValue, question: question.question, answer: answer.text,
                                                        right: right, method: answer.method.rawValue, note: answer.note,
                                                        seconds: Date.now.timeIntervalSince(started)))
                        }
                    }
                }
                context.delete(document)
                try context.save()
            } catch {
                report.error = String(describing: error)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: output.appending(path: file.deletingPathExtension().lastPathComponent + ".json"))
        }
        #expect(bloodTypeAnswered > 0, "the blood type was never answered; see \(output.path())")
    }
}
