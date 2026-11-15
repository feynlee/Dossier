import Foundation

/// Where a document sits in the library, and what it's called there: Mei › Immigration › EAD cards ›
/// "Mei · EAD card C09 · 2024-05-01 to 2026-04-30". The person level is left out while every document
/// belongs to one person.
nonisolated struct LibraryPlacement: Codable, Equatable, Hashable, Sendable {
    /// The holder's first name, or `LibraryPlacement.household` for documents about several people.
    var person: String
    var category: String
    var folder: String
    /// The file name without its extension.
    var name: String

    static let household = "Household"

    /// Folder names from the top, for a library with several people or with one.
    func path(showingPerson: Bool) -> [String] {
        showingPerson ? [person, category, folder] : [category, folder]
    }
}

/// What the library needs to know about a document to place and name it. Names are visible in Files and to
/// every site you upload to, so they're made only from the non-sensitive facts here. The birth date and
/// identity keys only tell people apart and never appear in a name.
nonisolated struct LibraryFacts: Equatable, Sendable {
    var kind: DocumentKind
    var title: String
    /// The holder's given names as printed, or nil when the document isn't about one person.
    var givenNames: String?
    var surname: String?
    /// A short, non-sensitive detail: an EAD or visa category, a USCIS form, a lease's street.
    var category: String?
    var formType: String?
    var address: String?
    var from: SimpleDate?
    var until: SimpleDate?
    /// A single date, for documents without a period (a notice, a record).
    var date: SimpleDate?
    /// "back" for the back of a card stored as its own file.
    var side: String?
    var fileExtension: String
    /// The holder's birth date, to tell whether two documents are about the same person.
    var dateOfBirth: SimpleDate? = nil
    /// Keyed hashes of numbers that belong to one person for life (the A-Number): documents that share one
    /// are about the same person. Never the numbers themselves.
    var identityKeys: [String] = []
}

nonisolated enum LibraryNaming {
    /// The starter categories the model's layouts follow.
    static let starterCategories = ["Identity", "Immigration", "Housing", "Health", "Tax and money", "Education", "Work", "Other"]

    /// Category, folder and the type word for kinds Dossier recognises. Other kinds are placed by the model.
    static func rule(for kind: DocumentKind) -> (category: String, folder: String, type: String)? {
        switch kind {
        case .passport: ("Identity", "Passports", "Passport")
        case .driversLicense: ("Identity", "Driver’s licences", "Driver’s licence")
        case .stateID: ("Identity", "State IDs", "State ID")
        case .greenCard: ("Immigration", "Green cards", "Green card")
        case .employmentAuthorization: ("Immigration", "EAD cards", "EAD card")
        case .visa: ("Immigration", "Visas", "Visa")
        case .uscisNotice: ("Immigration", "USCIS notices", "USCIS notice")
        case .i94: ("Immigration", "I-94 records", "I-94")
        case .lease: ("Housing", "Leases", "Lease")
        case .other, .addedByYou: nil
        }
    }

    /// Leases cover a home, not one person.
    static func isHousehold(_ kind: DocumentKind) -> Bool { kind == .lease }

    /// The holder's first name: the first of their given names, in title case.
    static func firstName(_ givenNames: String?) -> String? {
        guard let first = givenNames?.split(whereSeparator: { $0 == " " || $0 == "," }).first else { return nil }
        let name = String(first).lowercased().capitalized
        return name.isEmpty ? nil : name
    }

    /// The name of a document of a kind with a rule; `type` overrides the rule's word (the model's, for other
    /// kinds). "Mei · EAD card C09 · 2024-05-01 to 2026-04-30 (back)".
    static func name(for facts: LibraryFacts, person: String, type: String? = nil, detail: String? = nil) -> String {
        let type = type ?? rule(for: facts.kind)?.type ?? facts.title
        let detail = detail ?? Self.detail(for: facts)
        var parts = [person, [type, detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")]
        if let dates = dates(for: facts) { parts.append(dates) }
        var name = parts.map(clean).filter { !$0.isEmpty }.joined(separator: " · ")
        if let side = facts.side, !side.isEmpty { name += " (\(clean(side)))" }
        return name
    }

    /// The one short detail a known kind's name carries.
    static func detail(for facts: LibraryFacts) -> String? {
        switch facts.kind {
        case .employmentAuthorization, .visa, .greenCard: facts.category.map(compactCategory)
        case .uscisNotice: facts.formType
        case .lease: facts.address.flatMap(street)
        default: nil
        }
    }

    /// "C09" for "(c)(9)" or "C9", the way EAD categories are written on file names.
    static func compactCategory(_ category: String) -> String {
        let letters = category.uppercased().filter { $0.isLetter || $0.isNumber }
        guard let letter = letters.first, letter.isLetter, let number = Int(letters.dropFirst().prefix { $0.isNumber }) else {
            return letters
        }
        let rest = letters.dropFirst().drop { $0.isNumber }
        return String(format: "%@%02d", String(letter), number) + rest
    }

    /// "88 Pine Ave" from "88 Pine Ave, Apt 4, Seattle, WA 98101".
    static func street(_ address: String) -> String? {
        let first = address.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? nil : first
    }

    /// "2024-05-01 to 2026-04-30", one date, or nil. Year first, so names sort by date in Files.
    static func dates(for facts: LibraryFacts) -> String? {
        switch (facts.from, facts.until) {
        case let (from?, until?): "\(from.iso) to \(until.iso)"
        case let (nil, until?): facts.date.map { "\($0.iso) to \(until.iso)" } ?? "to \(until.iso)"
        case let (from?, nil): "from \(from.iso)"
        case (nil, nil): facts.date?.iso
        }
    }

    /// Takes out characters Files can't show in a name, and runs of spaces.
    static func clean(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let kept = text.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        return kept.split(separator: " ").joined(separator: " ")
    }

    /// The name, or the name with " (2)", " (3)"… when another document in the folder already has it.
    static func unique(_ name: String, among taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) (\(number))") { number += 1 }
        return "\(name) (\(number))"
    }

    /// Whether a name could reveal a number Dossier keeps sealed: any run of 6 or more digits that isn't a
    /// date. Used to drop a model's detail that copied one.
    static func mayRevealNumber(_ text: String) -> Bool {
        let withoutDates = text.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        return withoutDates.range(of: #"[A-Z]{0,3}\d[\d -]{4,}\d"#, options: .regularExpression) != nil
    }
}
