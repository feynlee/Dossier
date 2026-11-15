import AppIntents
import CoreSpotlight
import os
import FoundationModels
import SwiftData
import SwiftUI

// Siri over everything Dossier has read. Two ways in:
// - "Ask Dossier" takes any question in your own words and answers it from the knowledge layer: rules for the
//   common questions, then a language model given the reconciled facts.
// - Each topic ("Anna · Passport · Expires") is an entity Siri and Shortcuts can find by name, and can put in
//   Spotlight's semantic index when you turn that on, so Siri can find it without "Dossier" in the question.
// Like the other intents, both need the iPhone unlocked and never say more than the last four characters of a
// sensitive number.

/// How a question is answered. The app uses `.automatic`; the others exist so the answer evaluation can
/// compare them.
nonisolated enum AnswerStrategy: String, CaseIterable, Sendable {
    /// Rules first; if they can't decide, Private Cloud Compute, then the on-device model.
    case automatic
    case rulesOnly
    case onDeviceOnly
    case privateCloudOnly
    case rulesThenOnDevice
}

enum KnowledgeService {
    static let notFound = KnowledgeAnswer.notFound

    static func answer(_ text: String, knowledge: Knowledge, strategy: AnswerStrategy = .automatic) async -> KnowledgeAnswer {
        let question = KnowledgeQuestion(text, knowledge: knowledge)
        let rules = { RuleAnswerer.answer(question, in: knowledge) }
        let device = { () async -> KnowledgeAnswer? in
            guard SystemLanguageModel.default.isAvailable else { return nil }
            return try? await ModelAnswerer(engine: .onDevice).answer(question, in: knowledge)
        }
        let cloud = { () async -> KnowledgeAnswer? in
            guard DocumentExtractor.privateCloudStatus() == nil else { return nil }
            return try? await ModelAnswerer(engine: .privateCloud).answer(question, in: knowledge)
        }
        var result: KnowledgeAnswer?
        switch strategy {
        case .rulesOnly: result = rules()
        case .onDeviceOnly: result = await device()
        case .privateCloudOnly: result = await cloud()
        case .rulesThenOnDevice:
            result = rules()
            if result == nil { result = await device() }
        case .automatic:
            result = rules()
            if result?.found != true { result = await cloud() ?? result }
            if result?.found != true { result = await device() ?? result }
        }
        return result ?? KnowledgeAnswer(text: notFound, method: .rules, topicIDs: [], sources: [], found: false)
    }
}

// MARK: Ask Dossier

struct AskDossierIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Dossier"
    static let description = IntentDescription("Answers a question about your documents and your family’s: dates, numbers, addresses, vaccinations, results, rent, income and more.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String

    init() {}
    init(question: String) { self.question = question }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let knowledge = try KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext)
        SiriLog.asked("Ask Dossier", question, knowledge)
        let answer = await KnowledgeService.answer(question, knowledge: knowledge)
        SiriLog.answered(answer)
        return .result(dialog: "\(answer.text)") { AnswerSnippet(answer: answer) }
    }
}

struct AnswerSnippet: View {
    let answer: KnowledgeAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DOSSIER").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(answer.text).font(.body)
            if !answer.sources.isEmpty {
                Text("From " + answer.sources.map(\.title).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if answer.hiddenFactID != nil {
                Text("Open Dossier to see the full number").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

// MARK: Search

/// Siri's own "search in Dossier for …": with Apple Intelligence, Siri looks for an app's search action when
/// you ask it to find something in that app. Without one it said "I can't search within Dossier" on Li's
/// iPhone, though Try a question answered the same question. Answers like Ask Dossier.
@AppIntent(schema: .system.search)
struct SearchDossierIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let knowledge = try KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext)
        SiriLog.asked("Search", criteria.term, knowledge)
        let answer = await KnowledgeService.answer(criteria.term, knowledge: knowledge)
        SiriLog.answered(answer)
        return .result(dialog: "\(answer.text)") { AnswerSnippet(answer: answer) }
    }
}

// MARK: Topics as entities

struct KnowledgeEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dossier fact"
    static let defaultQuery = KnowledgeEntityQuery()

    var id: String
    /// "Anna · Passport · Expires"
    @Property(title: "Name") var name: String
    /// The answer as it may be shown without Face ID: "14 Mar 2029", "ends in 4821".
    @Property(title: "Value") var value: String
    @Property(title: "Person") var person: String
    var isSensitive: Bool

    /// "My blood type" for "Health summary · Blood type": what people say.
    var shortName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(value)", image: nil, synonyms: ["\(shortName)"])
    }

    /// Sensitive values stay out of Spotlight even when indexing is on.
    var hideInSpotlight: Bool { isSensitive }

    init(_ topic: KnowledgeTopic, knowledge: Knowledge) {
        id = topic.id
        isSensitive = topic.current?.value.isSensitive ?? false
        let subject = topic.person == knowledge.owner ? "My" : topic.person.possessive
        // Plain stored properties first: `name` is an @Property, and setting it uses self.
        let label = topic.name.components(separatedBy: " · ").last ?? topic.name
        shortName = "\(subject) \(label)".lowercased().capitalizedFirst
        name = "\(subject) \(topic.name.replacingOccurrences(of: " · ", with: " "))".lowercased().capitalizedFirst
        value = topic.current.map { claim in
            if topic.behavior == .event, let date = claim.date { return date.display + (claim.label.map { " · \($0)" } ?? "") }
            return claim.value.text.map { SimpleDate(iso: $0)?.display ?? $0 } ?? "ends in \(claim.value.hint ?? "····")"
        } ?? "Unknown"
        person = topic.person
    }
}

struct KnowledgeEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [KnowledgeEntity] {
        let knowledge = try KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext)
        return knowledge.topics.filter { identifiers.contains($0.id) }.map { KnowledgeEntity($0, knowledge: knowledge) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [KnowledgeEntity] {
        let knowledge = try KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext)
        SiriLog.asked("Fact search", string, knowledge)
        let question = KnowledgeQuestion(string, knowledge: knowledge)
        return KnowledgeSearch.search(question, in: knowledge, limit: 8).map { KnowledgeEntity($0.topic, knowledge: knowledge) }
    }

    @MainActor
    func suggestedEntities() async throws -> [KnowledgeEntity] {
        let knowledge = try KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext)
        return Self.suggested(knowledge).map { KnowledgeEntity($0, knowledge: knowledge) }
    }

    /// The facts Siri can name in "What's … in Dossier": yours first, then the household's, then your
    /// family's. Before, only the first 60 topics were offered, so in a full vault your blood type (read
    /// late, from a health record) was never one Siri knew.
    nonisolated static func suggested(_ knowledge: Knowledge) -> [KnowledgeTopic] {
        let topics = knowledge.topics.filter { $0.behavior != .event || $0.name.hasPrefix("Vaccinations") }
        func rank(_ topic: KnowledgeTopic) -> Int {
            if topic.person == knowledge.owner { return 0 }
            return topic.person == KnowledgeBuilder.household ? 1 : 2
        }
        return Array(topics.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element).prefix(limit))
    }

    nonisolated static let limit = 400
}

struct GetFactIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a fact from Dossier"
    static let description = IntentDescription("Tells you one thing from your documents, such as your passport’s expiry date or your last tetanus shot.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Fact") var fact: KnowledgeEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        SiriLog.logger.notice("Get a fact: \(fact.id, privacy: .public)")
        let spoken = "\(fact.name) is \(fact.value)."
        return .result(value: fact.value, dialog: "\(spoken)")
    }
}

/// Puts the non-sensitive topics in Spotlight's semantic index, so Siri can find them without "Dossier" in the
/// question. Off unless you turn it on in Settings: indexed values show in Spotlight on an unlocked iPhone.
enum KnowledgeIndexer {
    static let settingKey = "indexKnowledgeInSpotlight"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    @MainActor
    static func refresh() async {
        let index = CSSearchableIndex.default()
        guard isOn, let knowledge = try? KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext) else {
            try? await index.deleteAppEntities(ofType: KnowledgeEntity.self)
            return
        }
        let entities = knowledge.topics.map { KnowledgeEntity($0, knowledge: knowledge) }.filter { !$0.isSensitive }
        try? await index.deleteAppEntities(ofType: KnowledgeEntity.self)
        do {
            try await index.indexAppEntities(entities)
            SiriLog.logger.notice("Spotlight: indexed \(entities.count) facts")
        } catch {
            SiriLog.logger.error("Spotlight: indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// What Siri asked and what Dossier found, in the device log (Console › subsystem liziyue.Dossier, category Siri),
/// to tell a question Dossier couldn't answer from one that never reached it. Names of facts only, never values.
enum SiriLog {
    static let logger = Logger(subsystem: "liziyue.Dossier", category: "Siri")

    static func asked(_ route: String, _ text: String, _ knowledge: Knowledge) {
        let question = KnowledgeQuestion(text, knowledge: knowledge)
        let top = KnowledgeSearch.search(question, in: knowledge, limit: 5)
            .map { "\($0.topic.person) · \($0.topic.name) (\(String(format: "%.1f", $0.score)))" }.joined(separator: "; ")
        logger.notice("\(route, privacy: .public): \"\(text, privacy: .public)\" · owner \(knowledge.owner ?? "none", privacy: .public) · \(knowledge.topics.count) facts · about \(question.people.joined(separator: ","), privacy: .public) · top: \(top, privacy: .public)")
    }

    static func answered(_ answer: KnowledgeAnswer) {
        logger.notice("Answered by \(answer.method.rawValue, privacy: .public), found \(answer.found) · \(answer.note ?? "", privacy: .public)")
    }
}
