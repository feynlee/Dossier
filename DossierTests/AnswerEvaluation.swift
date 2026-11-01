import Foundation
import Testing
@testable import Dossier

nonisolated enum AnswerEvaluationEnvironment {
    static var output: URL? {
        ProcessInfo.processInfo.environment["DOSSIER_ANSWER_OUT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

/// Asks every question in SampleDocuments/Household/questions.json with each way of answering, and writes the
/// answers for `Tools/household/score_answers.py`. The knowledge comes from the answer key (testing answering
/// on its own) and, when DOSSIER_ANSWER_READINGS points at ReadingEvaluation's output, from what Dossier
/// actually read (testing everything together). Off unless DOSSIER_ANSWER_OUT is set:
///
///     TEST_RUNNER_DOSSIER_ANSWER_OUT=/path/answers \
///     TEST_RUNNER_DOSSIER_ANSWER_READINGS=/path/results/pcc \
///     TEST_RUNNER_DOSSIER_ANSWER_STRATEGIES=rulesOnly,onDeviceOnly,privateCloudOnly,automatic \
///     xcodebuild test … -only-testing:DossierTests/AnswerEvaluation
@Suite(.enabled(if: AnswerEvaluationEnvironment.output != nil), .serialized)
struct AnswerEvaluation {
    struct Row: Codable {
        var strategy: String
        var knowledge: String
        var question: String
        var expected: String
        var accept: [String]
        var sensitive: Bool
        var kind: String
        var answer: String
        var method: String
        var found: Bool
        var topics: [String]
        var seconds: Double
        var note: String?
    }

    @Test(.timeLimit(.minutes(60)))
    func askEverything() async throws {
        let output = try #require(AnswerEvaluationEnvironment.output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let strategies = (environment["DOSSIER_ANSWER_STRATEGIES"] ?? "rulesOnly,onDeviceOnly,privateCloudOnly,automatic")
            .split(separator: ",").compactMap { AnswerStrategy(rawValue: String($0)) }
        var sources: [(String, Knowledge)] = [("answerKey", KnowledgeBuilder.build(try HouseholdFixture.groundTruth(), today: HouseholdFixture.today))]
        if let readings = environment["DOSSIER_ANSWER_READINGS"] {
            let documents = try HouseholdFixture.readings(in: URL(filePath: readings, directoryHint: .isDirectory))
            sources.append(("readings", KnowledgeBuilder.build(documents, today: HouseholdFixture.today)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for (name, knowledge) in sources {
            // What the model sees, for reading along with the answers.
            try encoder.encode(knowledge).write(to: output.appending(path: "knowledge-\(name).json"))
            for strategy in strategies {
                var rows: [Row] = []
                for question in try HouseholdFixture.questions() {
                    let started = Date.now
                    let answer = await KnowledgeService.answer(question.question, knowledge: knowledge, strategy: strategy)
                    rows.append(Row(
                        strategy: strategy.rawValue, knowledge: name, question: question.question, expected: question.answer,
                        accept: question.accept, sensitive: question.sensitive, kind: question.kind, answer: answer.text,
                        method: answer.method.rawValue, found: answer.found, topics: answer.topicIDs, seconds: Date.now.timeIntervalSince(started),
                        note: answer.note
                    ))
                }
                try encoder.encode(rows).write(to: output.appending(path: "answers-\(name)-\(strategy.rawValue).json"))
            }
        }
    }
}
