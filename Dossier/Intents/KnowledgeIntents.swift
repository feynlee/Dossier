import AppIntents
import CoreSpotlight
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
            return await limited { try await ModelAnswerer(engine: .onDevice).answer(question, in: knowledge) }
        }
        let cloud = { () async -> KnowledgeAnswer? in
            guard DocumentExtractor.privateCloudStatus() == nil else { return nil }
            return await limited { try await ModelAnswerer(engine: .privateCloud).answer(question, in: knowledge) }
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

    /// How long one model may take before Siri moves on. Seen in testing: on-device answers that the checks
    /// then refused took 60 to 75 seconds.
    static let modelTimeLimit: Duration = .seconds(12)

    /// The model's answer, or nil when it fails or takes longer than `modelTimeLimit`.
    static func limited(_ work: @escaping @Sendable () async throws -> KnowledgeAnswer) async -> KnowledgeAnswer? {
        let limit = modelTimeLimit
        return await withTaskGroup(of: KnowledgeAnswer?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
        let answer = await KnowledgeService.answer(question, knowledge: knowledge)
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

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(value)")
    }

    /// Sensitive values stay out of Spotlight even when indexing is on.
    var hideInSpotlight: Bool { isSensitive }

    init(_ topic: KnowledgeTopic, knowledge: Knowledge) {
        id = topic.id
        isSensitive = topic.current?.value.isSensitive ?? false
        let subject = topic.person == knowledge.owner ? "My" : topic.person.possessive
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
        let question = KnowledgeQuestion(string, knowledge: knowledge)
        return KnowledgeSearch.search(question, in: knowledge, limit: 8).map { KnowledgeEntity($0.topic, knowledge: knowledge) }
    }

    @MainActor
    func suggestedEntities() async throws -> [KnowledgeEntity] {
        let knowledge = try KnowledgeSnapshot.knowledge(in: VaultStore.container.mainContext)
        return knowledge.topics
            .filter { $0.behavior != .event || $0.name.hasPrefix("Vaccinations") }
            .prefix(60)
            .map { KnowledgeEntity($0, knowledge: knowledge) }
    }
}

struct GetFactIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a fact from Dossier"
    static let description = IntentDescription("Tells you one thing from your documents, such as your passport’s expiry date or your last tetanus shot.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Fact") var fact: KnowledgeEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
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
        try? await index.indexAppEntities(entities)
    }
}
