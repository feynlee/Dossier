import Foundation
import FoundationModels

/// An answer to a question about your documents, with where it came from.
nonisolated struct KnowledgeAnswer: Sendable, Codable {
    enum Method: String, Sendable, Codable { case rules, onDevice, privateCloud }

    /// What Siri says. Never more than the last four characters of a sensitive number.
    var text: String
    var method: Method
    /// The topics the answer used, best first.
    var topicIDs: [String]
    /// The documents behind it, for the snippet and "open in Dossier".
    var sources: [KnowledgeSource]
    /// A sensitive value the answer refers to, which the snippet can reveal after Face ID.
    var hiddenFactID: String?
    var found: Bool
}

// MARK: Rules

/// Answers the questions plain rules can: one topic's value, counts of events, a year in your address history,
/// days abroad, what expires next. Instant and offline; the model handles the rest.
nonisolated enum RuleAnswerer {
    static func answer(_ question: KnowledgeQuestion, in knowledge: Knowledge) -> KnowledgeAnswer? {
        if question.wantsExpiries { return expiries(question, knowledge) }
        if let trips = travel(question, knowledge) { return trips }
        let matches = KnowledgeSearch.search(question, in: knowledge, limit: 5)
        guard let top = matches.first else { return nil }
        // Too close to call: leave it to the model.
        if matches.count > 1, matches[1].score > top.score * 0.92, matches[1].topic.current?.value != top.topic.current?.value { return nil }
        let topic = top.topic
        let subject = KnowledgeSpeech.subject(topic.person, knowledge: knowledge)

        if let year = question.year, topic.id.hasSuffix("|state|address") {
            let homes = topic.claims.filter { claim in
                guard let from = claim.validFrom ?? claim.date else { return false }
                let to = claim.validUntil ?? knowledge.today
                return from.year <= year && year <= to.year && (claim.source.kind == .lease || claim.source.kind == .addedByYou)
            }
            guard let home = homes.last ?? homes.first else { return nil }
            let lived = topic.person == knowledge.owner ? "you lived" : "\(topic.person) lived"
            return make("In \(year) \(lived) at \(home.value.spoken).", topic, [home])
        }
        if question.wantsCount, topic.behavior == .event {
            var claims = topic.claims
            let specific = question.words.filter { word in claims.contains { KnowledgeText.words($0.label ?? "").contains(word) } }
            if !specific.isEmpty { claims = claims.filter { claim in specific.contains { KnowledgeText.words(claim.label ?? "").contains($0) } } }
            let dates = claims.compactMap(\.date).sorted().map(\.spoken)
            return make("\(subject.capitalizedFirst) \(subject == "you" ? "have" : "has") \(claims.count) on file: \(dates.joined(separator: ", ")).", topic, claims)
        }
        var picked = topic.current
        if question.wantsPast, topic.behavior != .identity, let old = topic.others.first { picked = old }
        guard let claim = picked else { return nil }
        var text: String
        if topic.behavior == .event, let date = claim.date {
            text = "\(subject.possessive.capitalizedFirst) \(KnowledgeSpeech.topicName(topic)) was on \(date.spoken)" + (claim.label.map { " (\($0))" } ?? "")
        } else if let sentence = KnowledgeSpeech.dateSentence(topic, claim, subject: subject, today: knowledge.today) {
            text = sentence
        } else {
            text = "\(subject.possessive.capitalizedFirst) \(KnowledgeSpeech.topicName(topic)) is \(KnowledgeSpeech.value(claim.value))"
        }
        text += claim.source.title.isEmpty ? "." : ", from \(claim.source.title)."
        return make(text, topic, [claim])
    }

    static func make(_ text: String, _ topic: KnowledgeTopic, _ claims: [KnowledgeClaim]) -> KnowledgeAnswer {
        KnowledgeAnswer(
            text: text, method: .rules, topicIDs: [topic.id], sources: Array(Set(claims.map(\.source))).sorted { $0.title < $1.title },
            hiddenFactID: claims.first { $0.value.isSensitive }?.value.factID, found: true
        )
    }

    static func expiries(_ question: KnowledgeQuestion, _ knowledge: Knowledge) -> KnowledgeAnswer? {
        let keys = [FactKey.expiryDate, .validUntil, .leaseEndDate].map(\.rawValue)
        let limit = question.year.flatMap { SimpleDate(year: $0, month: 12, day: 31) }
        let upcoming = knowledge.topics
            .filter { $0.behavior == .credential && keys.contains($0.current?.field ?? "") }
            .compactMap { topic -> (KnowledgeTopic, SimpleDate)? in
                guard let date = topic.current?.value.text.flatMap(KnowledgeText.date), date >= knowledge.today else { return nil }
                if let limit, date > limit { return nil }
                return (topic, date)
            }
            .sorted { $0.1 < $1.1 }
        guard !upcoming.isEmpty else {
            return KnowledgeAnswer(text: "Nothing on file expires\(limit.map { " before \($0.spoken)" } ?? " soon").", method: .rules, topicIDs: [], sources: [], found: true)
        }
        let shown = question.text.lowercased().contains("next") ? Array(upcoming.prefix(1)) : upcoming
        let list = shown.map { topic, date in
            "\(KnowledgeSpeech.subject(topic.person, knowledge: knowledge).possessive) \(topic.name.components(separatedBy: " · ").first!.lowercased()) on \(date.spoken)"
        }
        return KnowledgeAnswer(
            text: "Coming up: \(KnowledgeSpeech.list(list)).", method: .rules, topicIDs: shown.map { $0.0.id },
            sources: shown.compactMap { $0.0.current?.source }, found: true
        )
    }

    static func travel(_ question: KnowledgeQuestion, _ knowledge: Knowledge) -> KnowledgeAnswer? {
        let words = Set(question.words)
        let trips = knowledge.trips.filter { question.people.contains($0.person) }
        guard !trips.isEmpty else { return nil }
        if question.wantsDays, let year = question.year, words.contains("outside") || words.contains("abroad") || words.contains("away") {
            let days = trips.map { $0.daysAbroad(in: year, today: knowledge.today) }.reduce(0, +)
            let count = trips.filter { $0.daysAbroad(in: year, today: knowledge.today) > 0 }.count
            return KnowledgeAnswer(text: "In \(year) you spent \(days) days outside the US, over \(count) trip\(count == 1 ? "" : "s").",
                                   method: .rules, topicIDs: [], sources: [], found: true)
        }
        if question.wantsCount, words.contains("trips") || words.contains("trip") {
            let counted = trips.filter { trip in question.sinceYear.map { trip.departure.year >= $0 } ?? true }
            let since = question.sinceYear.map { " since \($0)" } ?? ""
            return KnowledgeAnswer(text: "You've taken \(counted.count) trip\(counted.count == 1 ? "" : "s") abroad\(since).",
                                   method: .rules, topicIDs: [], sources: [], found: true)
        }
        return nil
    }
}

// MARK: Speech

nonisolated enum KnowledgeSpeech {
    /// "you" for the owner, otherwise their name.
    static func subject(_ person: String, knowledge: Knowledge) -> String {
        person == knowledge.owner || person == KnowledgeBuilder.household ? "you" : person
    }

    /// "Vaccinations · Tetanus (Td, Tdap, DTaP)" → "last tetanus (td, tdap, dtap) dose".
    static func topicName(_ topic: KnowledgeTopic) -> String {
        let parts = topic.name.components(separatedBy: " · ")
        switch topic.behavior {
        case .event: return "last " + parts.last!.lowercased() + (parts.first == "Vaccinations" ? " dose" : "")
        default: return parts.map { $0.lowercased() }.joined(separator: " ")
        }
    }

    /// "Your passport expires 14 March 2029", "Your lease ended 30 June 2026": dates read naturally.
    static func dateSentence(_ topic: KnowledgeTopic, _ claim: KnowledgeClaim, subject: String, today: SimpleDate) -> String? {
        guard let key = FactKey(rawValue: claim.field), key.isDate, let date = claim.value.text.flatMap(KnowledgeText.date) else { return nil }
        let thing = topic.name.components(separatedBy: " · ").first!.lowercased()
        let past = date < today
        let owner = subject.possessive.capitalizedFirst
        switch key {
        case .expiryDate, .validUntil, .admitUntil: return "\(owner) \(thing) \(past ? "expired" : "expires") \(date.spoken)"
        case .leaseEndDate: return "\(owner) \(thing) \(past ? "ended" : "ends") \(date.spoken)"
        case .leaseStartDate, .validFrom: return "\(owner) \(thing) \(past ? "started" : "starts") \(date.spoken)"
        case .issueDate: return "\(owner) \(thing) was issued \(date.spoken)"
        case .noticeDate: return "\(owner) \(thing) is dated \(date.spoken)"
        case .residentSince: return "\(subject == "you" ? "You've" : "\(subject) has") been a permanent resident since \(date.spoken)"
        case .dateOfBirth: return "\(subject == "you" ? "You were" : "\(subject) was") born on \(date.spoken)"
        default: return nil
        }
    }

    /// ISO dates read as "14 March 2029"; sensitive values as "a number ending in 4821".
    static func value(_ value: KnowledgeValue) -> String {
        guard let text = value.text else { return value.spoken }
        guard let regex = try? Regex(#"\b\d{4}-\d{2}-\d{2}\b"#) else { return text }
        var out = ""
        var rest = text.startIndex
        for match in text.matches(of: regex) {
            out += text[rest..<match.range.lowerBound]
            let found = String(text[match.range])
            out += SimpleDate(iso: found)?.spoken ?? found
            rest = match.range.upperBound
        }
        out += text[rest...]
        return out
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

extension String {
    nonisolated var possessive: String {
        switch self.lowercased() {
        case "you": return "your"
        default: return hasSuffix("s") ? self + "’" : self + "’s"
        }
    }

    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Model

@Generable(description: "An answer to a question about the person's own documents")
nonisolated struct KnowledgeModelReply {
    @Guide(description: "One or two short sentences to be spoken aloud, addressed to the person asking (you, your). Use only the facts given. Dates in words, like 14 March 2029. For a hidden number, say only that it ends in its last four characters. If the facts don't answer the question, say you couldn't find it in their documents.")
    var answer: String

    @Guide(description: "The ids of the facts the answer uses, such as F3, most important first. Empty if not found.")
    var factIDs: [String]

    @Guide(description: "answered when the facts answer the question; notFound otherwise.", .anyOf(["answered", "notFound"]))
    var outcome: String
}

/// Answers with a language model given the relevant facts as text. On this iPhone the model sees the topics
/// the search found; with Private Cloud Compute it sees every topic, so it can also answer questions the search
/// can't match. Sensitive numbers are never in the prompt: only their last four characters.
nonisolated struct ModelAnswerer {
    enum Engine: Sendable { case onDevice, privateCloud }

    static let instructions = """
        You answer questions about a person's own documents: passports, immigration papers, licences, leases, \
        medical and vaccination records, tax forms. You are given facts that were read from those documents, \
        already checked and reconciled: when documents disagree, the first value of a fact is the one to use \
        and its note says why. Answer from these facts only. Never guess or use outside knowledge. Keep the \
        answer short enough to be spoken. Say "you" for the person asking and use family members' names.
        """

    var engine: Engine

    func answer(_ question: KnowledgeQuestion, in knowledge: Knowledge) async throws -> KnowledgeAnswer {
        let topics: [KnowledgeTopic]
        switch engine {
        case .onDevice:
            topics = KnowledgeSearch.search(question, in: knowledge, limit: 10).map(\.topic)
        case .privateCloud:
            let relevant = question.isEveryone ? knowledge.topics : knowledge.topics.filter { question.people.contains($0.person) }
            let found = KnowledgeSearch.search(question, in: knowledge, limit: 10).map(\.topic)
            topics = found + relevant.filter { topic in !found.contains { $0.id == topic.id } }
        }
        let context = KnowledgeContext.render(topics, knowledge: knowledge, question: question)
        let session = engine == .privateCloud
            ? LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Self.instructions)
            : LanguageModelSession(model: SystemLanguageModel.default, instructions: Self.instructions)
        let prompt = "\(context.text)\n\nQuestion from \(knowledge.owner ?? "the owner"): \(question.text)"
        let reply = try await session.respond(to: prompt, generating: KnowledgeModelReply.self, options: GenerationOptions(samplingMode: .greedy)).content
        let used = reply.factIDs.compactMap { context.ids[$0] }
        let claims = used.compactMap { knowledge.topic($0) }.flatMap(\.claims)
        return KnowledgeAnswer(
            text: reply.answer, method: engine == .privateCloud ? .privateCloud : .onDevice, topicIDs: used,
            sources: Array(Set(used.compactMap { knowledge.topic($0)?.current?.source })),
            hiddenFactID: used.first.flatMap { knowledge.topic($0)?.current }.flatMap { $0.value.isSensitive ? $0.value.factID : nil }
                ?? claims.first { $0.value.isSensitive }?.value.factID,
            found: reply.outcome == "answered"
        )
    }
}

/// The facts as the model reads them: one line per topic, with short ids.
nonisolated enum KnowledgeContext {
    struct Rendered {
        var text: String
        /// "F3" → topic id.
        var ids: [String: String]
    }

    static func render(_ topics: [KnowledgeTopic], knowledge: Knowledge, question: KnowledgeQuestion) -> Rendered {
        var lines = ["Today is \(knowledge.today.spoken)."]
        let family = knowledge.people.map { person in
            person.isOwner ? "\(person.name) (the person asking)" : "\(person.name) (\(person.relation?.label.lowercased() ?? "family"))"
        }
        lines.append("People: \(family.joined(separator: ", ")).")
        let trips = knowledge.trips.filter { question.people.contains($0.person) }
        if !trips.isEmpty {
            let years = Set(trips.flatMap { [$0.departure.year, ($0.arrival ?? knowledge.today).year] }).sorted()
            var days: [String] = []
            for year in years {
                var total = 0
                for trip in trips { total += trip.daysAbroad(in: year, today: knowledge.today) }
                days.append("\(year): \(total) days")
            }
            lines.append("Days outside the US by year (travel days count as in the US): \(days.joined(separator: ", ")).")
            lines.append("Trips abroad: " + trips.map { "left \($0.departure.iso), back \($0.arrival?.iso ?? "not yet")" }.joined(separator: "; ") + ".")
        }
        lines.append("Facts:")
        var ids: [String: String] = [:]
        for (index, topic) in topics.enumerated() {
            let id = "F\(index + 1)"
            ids[id] = topic.id
            var line = "\(id) · \(topic.person) · \(topic.name): "
            if let current = topic.current { line += describe(current, behavior: topic.behavior) } else { line += "unknown" }
            let earlier = topic.others.prefix(6).map { describe($0, behavior: topic.behavior) }
            if !earlier.isEmpty { line += topic.behavior == .event ? " · earlier: " : " · other documents: " ; line += earlier.joined(separator: "; ") }
            if let note = topic.note { line += " · note: \(note)" }
            lines.append(line)
        }
        return Rendered(text: lines.joined(separator: "\n"), ids: ids)
    }

    static func describe(_ claim: KnowledgeClaim, behavior: KnowledgeTopic.Behavior) -> String {
        let value = claim.value.text ?? "[hidden number ending \(claim.value.hint ?? "????")]"
        var parts = [value]
        if let label = claim.label, behavior == .event, !value.contains(label) { parts.append(label) }
        var source = claim.source.title
        if let from = claim.validFrom, let to = claim.validUntil { source += ", \(from.iso) to \(to.iso)" }
        else if let date = claim.date, behavior != .event { source += ", \(date.iso)" }
        parts.append("(\(source))")
        return parts.joined(separator: " ")
    }
}
