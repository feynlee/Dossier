import Foundation

// Dossier's knowledge: everything read from the documents, organised into topics a person can ask about
// ("Anna · Passport · Expires", "Emma · Vaccinations · DTaP", "Anna · Address"), each with one resolved
// answer, the history behind it, and the documents it comes from. Built fresh from the vault whenever it's
// needed; nothing here is stored. Pure, so it is tested without SwiftData, and so Siri can use it from an
// intent without the app's UI.

// MARK: Input

/// How much a reading can be trusted, weakest first.
nonisolated enum KnowledgeStrength: Int, Comparable, Sendable, Codable {
    /// The model wasn't sure, or the verifier found a reason to doubt it: it's in Review.
    case doubtful
    /// Read by the model, not found in the page text (names and addresses read from the image).
    case model
    /// Read by the model and found in the page's own text.
    case pageText
    /// Matched a checksum-bearing source: the MRZ or the licence barcode.
    case checksum
    /// You confirmed or corrected it.
    case confirmed

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One value as read from a document. Sensitive values are never in the clear here: `text` is nil and `hint`
/// holds the last four characters, so answers can say "ends in 4821" and reveal the rest after Face ID.
nonisolated struct KnowledgeValue: Sendable, Equatable, Codable {
    var text: String?
    var hint: String?
    var isSensitive = false
    var strength: KnowledgeStrength = .pageText
    /// Identifies the stored fact, to reveal a sensitive value once you've passed Face ID.
    var factID: String?
    /// A keyed hash of the normalized value, so sensitive values can be compared without opening them.
    var fingerprint: String?

    static func plain(_ text: String, strength: KnowledgeStrength = .pageText) -> KnowledgeValue {
        KnowledgeValue(text: text, strength: strength)
    }

    /// What's safe to say aloud or show without Face ID.
    var spoken: String {
        if let text { return text }
        return hint.map { "a number ending in \($0)" } ?? "a hidden number"
    }

    /// For comparing two readings: the clear text, or the fingerprint of a sensitive value.
    var comparable: String? { text ?? fingerprint }
}

/// Something a document records besides its standard facts: a row of its contents (section, label, value) or
/// a detail about its holder or a family member.
nonisolated struct KnowledgeEntry: Sendable, Codable {
    /// The document's section for contents; nil for a detail.
    var section: String?
    var label: String
    var value: KnowledgeValue
    /// For a family member's detail: their relationship to the document's holder, and their name.
    var relation: Relation?
    var personName: String?
}

nonisolated struct KnowledgeTravelRow: Sendable, Codable, Equatable {
    var date: SimpleDate
    var isArrival: Bool
    var port: String
}

/// A document as the knowledge layer sees it: a snapshot with values opened (except sensitive ones).
nonisolated struct KnowledgeDocument: Sendable, Codable {
    var id: String
    var kind: DocumentKind
    var title: String
    /// Whose it is: the holder's first name as the library files it, `Household`, or nil when not sorted yet.
    var person: String?
    var fields: [FactKey: KnowledgeValue]
    var entries: [KnowledgeEntry] = []
    var travel: [KnowledgeTravelRow] = []
    var addedAt: Date = .distantPast

    func date(_ key: FactKey) -> SimpleDate? {
        fields[key]?.text.flatMap(KnowledgeText.date)
    }
}

// MARK: Output

nonisolated struct KnowledgeSource: Sendable, Hashable, Codable {
    var documentID: String
    var title: String
    var kind: DocumentKind
}

/// One document's statement about a topic.
nonisolated struct KnowledgeClaim: Sendable, Codable, Identifiable {
    var id: String { "\(source.documentID)#\(field)" }
    var value: KnowledgeValue
    /// The fact key or entry label it was read from.
    var field: String
    var source: KnowledgeSource
    /// When the document says this was so: the date of an event, or the document's own date.
    var date: SimpleDate?
    /// The span it holds for: a lease's term, a card's validity.
    var validFrom: SimpleDate?
    var validUntil: SimpleDate?
    /// Extra words that help find it, such as a vaccine's brand or a dose number.
    var label: String?
}

nonisolated struct KnowledgeTopic: Sendable, Codable, Identifiable {
    /// How the documents' claims combine into one answer. This is where disagreements are settled.
    enum Behavior: String, Sendable, Codable {
        /// Never changes: date and place of birth, legal name. Agreeing documents confirm each other; the
        /// strongest, most authoritative, most common reading wins; a lone outlier is flagged.
        case identity
        /// Changes over time: address, phone, employer, immigration status. The newest evidence wins and
        /// older values are history, not conflicts.
        case state
        /// A fact of one kind of document, of which you may have had several (passports, licences, leases).
        /// The document in force today wins; the others are history.
        case credential
        /// Things that happened: vaccine doses, trips. All of them count; the latest is "the last one".
        case event
    }

    var id: String
    /// Whose topic: a person's first name or `Household`.
    var person: String
    /// "Passport · Expires", "Vaccinations · Tetanus", "Address".
    var name: String
    var behavior: Behavior
    /// The answer, when there is one.
    var current: KnowledgeClaim?
    /// Every other claim, newest first: history, other documents, or the earlier events.
    var others: [KnowledgeClaim]
    /// Documents disagree and the rules couldn't settle it with confidence.
    var isConflict = false
    /// How it was settled, in a sentence, when that isn't obvious: "The 2023 lease ended early on 30 Jun 2026".
    var note: String?
    /// Lowercased words for finding the topic.
    var terms: [String]

    var claims: [KnowledgeClaim] { (current.map { [$0] } ?? []) + others }
}

nonisolated struct KnowledgePerson: Sendable, Codable, Hashable {
    /// The first name the library uses for them.
    var name: String
    var fullName: String?
    /// Their relationship to the vault's owner; nil for the owner.
    var relation: Relation?
    var isOwner: Bool { relation == nil }
}

nonisolated struct Knowledge: Sendable, Codable {
    var today: SimpleDate
    var owner: String?
    var people: [KnowledgePerson]
    var topics: [KnowledgeTopic]
    var trips: [KnowledgeTrip]

    func topics(for person: String) -> [KnowledgeTopic] { topics.filter { $0.person == person } }
    func topic(_ id: String) -> KnowledgeTopic? { topics.first { $0.id == id } }
    func person(_ name: String) -> KnowledgePerson? { people.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
}

/// A trip abroad from the I-94 travel history: departure and the next arrival.
nonisolated struct KnowledgeTrip: Sendable, Codable, Equatable {
    var person: String
    var departure: SimpleDate
    var arrival: SimpleDate?
    var departurePort: String
    var arrivalPort: String?

    /// Days outside the US within a year (both travel days counted as days in the US, as USCIS counts).
    func daysAbroad(in year: Int, today: SimpleDate) -> Int {
        let end = arrival ?? today
        guard let yearStart = SimpleDate(year: year, month: 1, day: 1), let yearEnd = SimpleDate(year: year, month: 12, day: 31) else { return 0 }
        let from = max(departure, yearStart), to = min(end, yearEnd)
        guard from <= to else { return 0 }
        let days = KnowledgeText.days(from: from, to: to)
        // Departure and arrival days count as days in the US.
        let startsInside = departure >= yearStart, endsInside = arrival != nil && end <= yearEnd
        return max(0, days + 1 - (startsInside ? 1 : 0) - (endsInside ? 1 : 0))
    }
}

// MARK: Text helpers

nonisolated enum KnowledgeText {
    /// The first date in a value: `2020-02-20`, `02/20/2020`, `20 Feb 2020` or `February 20, 2020`.
    static func date(_ text: String) -> SimpleDate? { dates(in: text).first }

    static func dates(in text: String) -> [SimpleDate] {
        var found: [(Range<String.Index>, SimpleDate)] = []
        let upper = text.uppercased()
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        func month(_ name: Substring) -> Int? { months.firstIndex(of: String(name.prefix(3))).map { $0 + 1 } }
        let patterns: [(String, (Regex<AnyRegexOutput>.Match) -> SimpleDate?)] = [
            (#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, { m in
                guard let y = Int(m.output[1].substring ?? ""), let mo = Int(m.output[2].substring ?? ""), let d = Int(m.output[3].substring ?? "") else { return nil }
                return SimpleDate(year: y, month: mo, day: d)
            }),
            (#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#, { m in
                guard let mo = Int(m.output[1].substring ?? ""), let d = Int(m.output[2].substring ?? ""), let y = Int(m.output[3].substring ?? "") else { return nil }
                return SimpleDate(year: y, month: mo, day: d)
            }),
            (#"\b(\d{1,2}) ([A-Z]{3})[A-Z]*\.? (\d{4})\b"#, { m in
                guard let d = Int(m.output[1].substring ?? ""), let mo = m.output[2].substring.flatMap(month), let y = Int(m.output[3].substring ?? "") else { return nil }
                return SimpleDate(year: y, month: mo, day: d)
            }),
            (#"\b([A-Z]{3})[A-Z]*\.? (\d{1,2}),? (\d{4})\b"#, { m in
                guard let mo = m.output[1].substring.flatMap(month), let d = Int(m.output[2].substring ?? ""), let y = Int(m.output[3].substring ?? "") else { return nil }
                return SimpleDate(year: y, month: mo, day: d)
            }),
        ]
        for (pattern, make) in patterns {
            guard let regex = try? Regex(pattern) else { continue }
            for match in upper.matches(of: regex) {
                if let date = make(match), !found.contains(where: { $0.0.overlaps(match.range) }) { found.append((match.range, date)) }
            }
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }.map { $0.1 }
    }

    static func days(from: SimpleDate, to: SimpleDate) -> Int {
        Int((to.date.timeIntervalSince(from.date) / 86_400).rounded())
    }

    /// Lowercased words, without punctuation: "Td/Tdap · dose 2" → ["td", "tdap", "dose", "2"].
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty }
    }

    /// Letters and digits only, uppercased, for comparing values: "88 Pine Ave." and "88 PINE AVE" match.
    static func compact(_ text: String) -> String {
        String(text.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// An address in a form two spellings of the same place share: abbreviations, no punctuation, no ZIP+4.
    static func address(_ text: String) -> String {
        let replacements = ["STREET": "ST", "AVENUE": "AVE", "APARTMENT": "APT", "UNIT": "APT", "SUITE": "STE", "NORTHWEST": "NW",
                            "NORTHEAST": "NE", "SOUTHWEST": "SW", "SOUTHEAST": "SE", "ROAD": "RD", "DRIVE": "DR", "BOULEVARD": "BLVD"]
        let words = text.uppercased().replacingOccurrences(of: "#", with: " APT ")
            .split { !($0.isLetter || $0.isNumber) }
            .map { replacements[String($0)] ?? String($0) }
        return words.joined(separator: " ")
    }

    /// The street line only ("88 PINE AVE"), for telling whether two documents name the same home.
    static func street(_ text: String) -> String {
        let first = text.split(separator: ",").first.map(String.init) ?? text
        let words = address(first).split(separator: " ")
        // Drop the unit: "412 ALDER ST APT 3B" and "412 ALDER ST" are the same building.
        if let apt = words.firstIndex(of: "APT") { return words[..<apt].joined(separator: " ") }
        return words.joined(separator: " ")
    }
}
