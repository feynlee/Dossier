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
    /// Why a model's reply was not used, for the answer evaluation: never spoken.
    var note: String?

    static let notFound = "I couldn’t find that in your documents."
}

// MARK: Rules

/// Answers the questions plain rules can: one topic's value, counts of events, a year in your address history,
/// days abroad, what expires next. Instant and offline; the model handles the rest.
nonisolated enum RuleAnswerer {
    static func answer(_ question: KnowledgeQuestion, in knowledge: Knowledge) -> KnowledgeAnswer? {
        if question.wantsExpiries { return expiries(question, knowledge) }
        if let trips = travel(question, knowledge) { return trips }
        if let home = addressInYear(question, knowledge) { return home }
        if let moved = moveDate(question, knowledge) { return moved }
        // Only topics that cover what the question is about: "when was my I-485 approved" must not be answered
        // with the one date topic that matches "when".
        let matches = KnowledgeSearch.search(question, in: knowledge, limit: 8).filter { covers($0.topic, question) }
        guard let top = matches.first else { return nil }
        // Too close to call: leave it to the model.
        // (Two topics saying the same thing, such as your birth date on the marriage certificate, aren't a tie.)
        if matches.count > 1, matches[1].score > top.score * 0.92, !sameAnswer(matches[1].topic.current?.value, top.topic.current?.value) { return nil }
        let topic = top.topic
        let subject = KnowledgeSpeech.subject(topic.person, knowledge: knowledge)
        if question.wantsCount, topic.behavior == .event {
            var claims = topic.claims
            let specific = question.words.filter { word in claims.contains { KnowledgeText.words($0.label ?? "").contains(word) } }
            if !specific.isEmpty { claims = claims.filter { claim in specific.contains { KnowledgeText.words(claim.label ?? "").contains($0) } } }
            let dates = claims.compactMap(\.date).sorted().map(\.spoken)
            return make("\(subject.capitalizedFirst) \(subject == "you" ? "have" : "has") \(claims.count) on file: \(dates.joined(separator: ", ")).", topic, claims)
        }
        var picked = named(in: topic, question) ?? topic.current
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

    /// Words that say what kind of answer is wanted rather than what it's about.
    static let genericWords: Set<String> = ["when", "where", "who", "date", "day", "number", "last", "current", "new", "now", "today", "name",
                                            "until", "valid", "s", "much", "long", "ago", "recent", "latest", "most", "kind", "type"]

    /// Whether two values say the same thing: the same date in any spelling, or the same letters and digits.
    static func sameAnswer(_ a: KnowledgeValue?, _ b: KnowledgeValue?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if let x = a.text.flatMap(KnowledgeText.date), let y = b.text.flatMap(KnowledgeText.date) { return x == y }
        guard let x = a.comparable, let y = b.comparable else { return false }
        return KnowledgeText.compact(x) == KnowledgeText.compact(y)
    }

    /// Whether a topic is about at least half of the question's specific words.
    static func covers(_ topic: KnowledgeTopic, _ question: KnowledgeQuestion) -> Bool {
        // "My father's name", "my mother's maiden name": only a detail about that relative answers it, and only
        // one about the thing asked (not the father's phone).
        let raw = Set(KnowledgeText.words(question.text.lowercased()).map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 })
        for relation in [Relation.mother, .father, .sibling] where !raw.isDisjoint(with: KnowledgeTerms.relationWords(relation)) {
            let parts = topic.id.components(separatedBy: "|")
            guard parts.count >= 5, parts[1] == "detail", parts[2] == relation.rawValue else { return false }
            let asked = Set(question.words).subtracting(KnowledgeTerms.relationWords(relation))
            let label = Set(KnowledgeText.words(parts[4]) + KnowledgeText.words(topic.name.lowercased()))
            if !asked.isEmpty, asked.isDisjoint(with: label), !asked.contains(where: { KnowledgeTerms.related($0).contains { label.contains($0) } }) { return false }
        }
        if KnowledgeSearch.hint(question, topic, isDate: false) == 0.5 { return false }
        let specific = Set(question.words.filter { !genericWords.contains($0) && !$0.allSatisfy(\.isNumber) })
        guard !specific.isEmpty else { return true }
        let terms = Set(topic.terms)
        let covered = specific.filter { word in
            terms.contains(word) || KnowledgeTerms.related(word).contains { terms.contains($0) }
                || word.count >= 4 && terms.contains { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }
        }
        return covered.count * 2 >= specific.count
    }

    /// The value from the document the question names, when it names one other than today's ("rent at Pine Ave").
    static func named(in topic: KnowledgeTopic, _ question: KnowledgeQuestion) -> KnowledgeClaim? {
        let claims = [topic.current].compactMap { $0 } + topic.others
        guard claims.count > 1 else { return nil }
        let asked = Set(question.words.filter { $0.count > 2 && !genericWords.contains($0) })
        func overlap(_ claim: KnowledgeClaim) -> Int {
            let words = KnowledgeText.words(claim.source.title) + KnowledgeText.words(claim.label ?? "")
            return Set(words).intersection(asked).count
        }
        let best = claims.max { overlap($0) < overlap($1) }!
        return overlap(best) > overlap(claims[0]) ? best : nil
    }

    /// "Where did we live in 2024?": the home on file for that year, from leases and your own edits.
    static func addressInYear(_ question: KnowledgeQuestion, _ knowledge: Knowledge) -> KnowledgeAnswer? {
        let words = Set(question.words)
        guard let year = question.year, !words.isDisjoint(with: ["live", "lived", "living", "address", "home", "reside", "resided", "stay", "stayed"]) else { return nil }
        let people = question.isEveryone ? [knowledge.owner].compactMap { $0 } + question.people : question.people
        for person in people {
            guard let topic = knowledge.topics.first(where: { $0.person == person && $0.id.hasSuffix("|state|address") }) else { continue }
            let homes = topic.claims.filter { claim in
                guard let from = claim.validFrom ?? claim.date else { return false }
                let to = claim.validUntil ?? knowledge.today
                return from.year <= year && year <= to.year && (claim.source.kind == .lease || claim.source.kind == .addedByYou)
            }
            // The home that covers most of the year.
            guard let home = homes.max(by: { daysIn(year, $0, knowledge) < daysIn(year, $1, knowledge) }) else { continue }
            let lived = question.isEveryone ? "you lived" : person == knowledge.owner ? "you lived" : "\(person) lived"
            return make("In \(year) \(lived) at \(home.value.spoken).", topic, [home])
        }
        return nil
    }

    private static func daysIn(_ year: Int, _ claim: KnowledgeClaim, _ knowledge: Knowledge) -> Int {
        guard let from = claim.validFrom ?? claim.date, let first = SimpleDate(year: year, month: 1, day: 1), let last = SimpleDate(year: year, month: 12, day: 31) else { return 0 }
        let start = max(from, first), end = min(claim.validUntil ?? knowledge.today, last)
        return end < start ? 0 : (end.year - start.year) * 366 + (end.month - start.month) * 31 + end.day - start.day
    }

    /// "When did we move out of Pine Ave?": the end (or start) of the lease for the place named.
    static func moveDate(_ question: KnowledgeQuestion, _ knowledge: Knowledge) -> KnowledgeAnswer? {
        let text = question.text.lowercased()
        let out = ["move out", "moved out", "leave", "left"].contains { text.contains($0) }
        let into = ["move in", "moved in", "move to", "moved to", "move into", "moved into"].contains { text.contains($0) }
        guard out || into else { return nil }
        let field = out ? FactKey.leaseEndDate.rawValue : FactKey.leaseStartDate.rawValue
        let people = question.isEveryone ? [knowledge.owner].compactMap { $0 } + question.people + [KnowledgeBuilder.household] : question.people + [KnowledgeBuilder.household]
        let asked = Set(question.words.filter { $0.count > 2 && !genericWords.contains($0) && !["move", "moved", "out", "into", "leave", "left"].contains($0) })
        var best: (KnowledgeTopic, KnowledgeClaim, Int)?
        for topic in knowledge.topics where people.contains(topic.person) && topic.id.hasSuffix("|\(field)") {
            for claim in topic.claims where claim.field == field {
                let words = Set(KnowledgeText.words(claim.source.title) + KnowledgeText.words(claim.label ?? ""))
                let score = words.intersection(asked).count
                if score > (best?.2 ?? 0) { best = (topic, claim, score) }
            }
        }
        guard let best else { return nil }
        let (topic, claim) = (best.0, best.1)
        // The lease's own date, shortened by an addendum or the next lease when one ended it early.
        guard let date = (out ? claim.validUntil : claim.validFrom) ?? claim.value.text.flatMap(KnowledgeText.date) else { return nil }
        let subject = question.isEveryone ? "you" : KnowledgeSpeech.subject(topic.person, knowledge: knowledge)
        let verb = out ? (date < knowledge.today ? "moved out" : "move out") : (date < knowledge.today ? "moved in" : "move in")
        return make("\(subject.capitalizedFirst) \(verb) on \(date.spoken), from \(claim.source.title).", topic, [claim])
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
            let relevant = question.isEveryone ? knowledge.topics : knowledge.topics.filter { question.people.contains($0.person) || question.maybeOwner.contains($0.person) }
            let found = KnowledgeSearch.search(question, in: knowledge, limit: 10).map(\.topic)
            topics = found + relevant.filter { topic in !found.contains { $0.id == topic.id } }
        }
        let context = KnowledgeContext.render(topics, knowledge: knowledge, question: question)
        let session = engine == .privateCloud
            ? LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Self.instructions)
            : LanguageModelSession(model: SystemLanguageModel.default, instructions: Self.instructions)
        let prompt = "\(context.text)\n\nQuestion from \(knowledge.owner ?? "the owner"): \(question.text)"
        let reply = try await session.respond(to: prompt, generating: KnowledgeModelReply.self, options: GenerationOptions(samplingMode: .greedy)).content
        var cited = reply.factIDs.filter { context.ids[$0] != nil }
        // The on-device model sometimes cites the wrong line: "done by Dr. Priya Raman" citing the exam date
        // beside the name. Then the facts the answer does rest on are cited instead, if they're few.
        let checked = { (ids: [String]) in Self.isGrounded(reply.answer, in: context.header + ids.compactMap { context.lines[$0] } + [question.text]) }
        if reply.outcome == "answered", !cited.isEmpty, !checked(cited) {
            let given = context.lines.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
            let resting = given.filter { checked(cited + [$0]) }
            if !resting.isEmpty, resting.count <= 2 { cited = resting + cited }
        }
        let used = cited.compactMap { context.ids[$0] }
        let claims = used.compactMap { knowledge.topic($0) }.flatMap(\.claims)
        // An answer must rest on the facts it cites. Seen in testing: with the right fact missing, the on-device
        // model made up a rent, a parking space, lab results and an employer's figures. It may repeat the
        // question's own words ("Your Immigration Medical Exam was with…").
        let isGrounded = checked(cited)
        let fitsRelation = Self.fitsRelation(used.compactMap { knowledge.topic($0) }, question)
        guard reply.outcome == "answered", !cited.isEmpty, isGrounded, fitsRelation else {
            let given = topics.map(\.id).joined(separator: ", ")
            let note = "outcome \(reply.outcome); cited \(reply.factIDs.joined(separator: " ")); grounded \(isGrounded); "
                + "relation \(fitsRelation); reply \"\(reply.answer)\"; given \(given)"
            return KnowledgeAnswer(text: KnowledgeAnswer.notFound, method: engine == .privateCloud ? .privateCloud : .onDevice,
                                   topicIDs: [], sources: [], found: false, note: note)
        }
        return KnowledgeAnswer(
            text: reply.answer, method: engine == .privateCloud ? .privateCloud : .onDevice, topicIDs: used,
            sources: Array(Set(used.compactMap { knowledge.topic($0)?.current?.source })),
            hiddenFactID: used.first.flatMap { knowledge.topic($0)?.current }.flatMap { $0.value.isSensitive ? $0.value.factID : nil }
                ?? claims.first { $0.value.isSensitive }?.value.factID,
            found: reply.outcome == "answered"
        )
    }
}

nonisolated extension ModelAnswerer {
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    /// Whether every number and month the answer says is in the facts it rests on. Single digits are let
    /// through: they're counts the answer works out ("4 doses") and days of the month.
    static func isGrounded(_ answer: String, in lines: [String]) -> Bool {
        let facts = lines.joined(separator: "\n").lowercased()
        let known = Set(numbers(in: facts))
        for number in numbers(in: answer) where number.count > 1 && !known.contains(number) { return false }
        let words = Set(KnowledgeText.words(answer))
        for month in months where words.contains(month) && !facts.contains(month) { return false }
        // Names too: the on-device model answered "my mother's maiden name" with a made-up "Linda Chen, born Wu".
        // "Emma's" is checked as "Emma".
        let names = answer.replacingOccurrences(of: "’", with: "'").split { !$0.isLetter && $0 != "'" }
            .map { word in word.hasSuffix("'s") ? String(word.dropLast(2)) : String(word) }
            .filter { $0.count >= 3 && $0.first!.isUppercase && !commonWords.contains($0.lowercased()) && !months.contains($0.lowercased()) }
        for name in names where !facts.contains(name.lowercased()) { return false }
        return true
    }

    /// Whether the cited facts are about the relative the question asks after, and that relative belongs to the
    /// person asked about. Seen in testing: "What's my father's name?" answered with the spouse's name, and
    /// "my mother's maiden name" with the spouse's mother's.
    static func fitsRelation(_ topics: [KnowledgeTopic], _ question: KnowledgeQuestion) -> Bool {
        let raw = Set(KnowledgeText.words(question.text.lowercased().replacingOccurrences(of: "’", with: "'"))
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 })
        for relation in [Relation.mother, .father, .sibling] where !raw.isDisjoint(with: KnowledgeTerms.relationWords(relation)) {
            let fits = topics.contains { topic in
                let parts = topic.id.components(separatedBy: "|")
                return parts.count >= 3 && parts[1] == "detail" && parts[2] == relation.rawValue
                    && (question.isEveryone || question.people.contains(topic.person))
            }
            if !fits { return false }
        }
        return true
    }

    static let commonWords: Set<String> = ["you", "your", "you're", "you've", "the", "yes", "its", "this", "that", "there", "from", "for", "and",
                                           "but", "since", "before", "after", "today", "united", "states", "has", "have", "had", "was", "were",
                                           "not", "none", "nothing", "couldn't", "monday", "tuesday", "wednesday", "thursday", "friday",
                                           "saturday", "sunday", "according", "based", "per", "with", "who", "which", "what", "when", "where",
                                           "she", "her", "his", "him", "they", "their", "our", "it's", "she's", "he's", "they're",
                                           "it", "ends", "ending", "number", "certificate", "dr", "mr", "mrs", "ms", "md"]

    /// Numbers as written, without thousands separators or a zero fraction: "$2,480.00" → "2480".
    static func numbers(in text: String) -> [String] {
        guard let regex = try? Regex(#"\d+(?:[.,]\d+)*"#) else { return [] }
        return text.matches(of: regex).flatMap { match -> [String] in
            var token = String(text[match.range])
            // "2,480" is one number; "1990-08-12" style runs are split by the regex already.
            if let dot = token.lastIndex(of: "."), token[token.index(after: dot)...].allSatisfy({ $0 == "0" }) { token = String(token[..<dot]) }
            let groups: [Substring] = token.split(separator: "," as Character)
            if groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 }) { return [groups.joined()] }
            return groups.map(String.init)
        }
    }
}

/// The facts as the model reads them: one line per topic, with short ids.
nonisolated enum KnowledgeContext {
    struct Rendered {
        var text: String
        /// "F3" → topic id.
        var ids: [String: String]
        /// The lines before the facts (today, people, travel), and each fact's line by id, to check answers against.
        var header: [String] = []
        var lines: [String: String] = [:]
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
            lines.append("Trips abroad: " + trips.map { "left \($0.departure.spoken), back \($0.arrival?.spoken ?? "not yet")" }.joined(separator: "; ") + ".")
        }
        let header = lines
        lines.append("Facts:")
        var ids: [String: String] = [:]
        var factLines: [String: String] = [:]
        for (index, topic) in topics.enumerated() {
            let id = "F\(index + 1)"
            ids[id] = topic.id
            var line = "\(id) · \(topic.person) · \(topic.name): "
            if let current = topic.current { line += describe(current, behavior: topic.behavior) } else { line += "unknown" }
            let earlier = topic.others.prefix(6).map { describe($0, behavior: topic.behavior) }
            if !earlier.isEmpty { line += topic.behavior == .event ? " · earlier: " : " · other documents: " ; line += earlier.joined(separator: "; ") }
            if let note = topic.note { line += " · note: \(note)" }
            lines.append(line)
            factLines[id] = line
        }
        return Rendered(text: lines.joined(separator: "\n"), ids: ids, header: header, lines: factLines)
    }

    static func describe(_ claim: KnowledgeClaim, behavior: KnowledgeTopic.Behavior) -> String {
        // Dates are written out ("1 March 2031") so the model repeats them instead of re-reading 2031-03-01.
        let value = claim.value.text != nil ? KnowledgeSpeech.value(claim.value) : "[hidden number ending \(claim.value.hint ?? "????")]"
        var parts = [value]
        if let label = claim.label, behavior == .event, !value.contains(label) { parts.append(label) }
        var source = claim.source.title
        if let from = claim.validFrom, let to = claim.validUntil { source += ", \(from.spoken) to \(to.spoken)" }
        else if let date = claim.date, behavior != .event { source += ", \(date.spoken)" }
        parts.append("(\(source))")
        return parts.joined(separator: " ")
    }
}
