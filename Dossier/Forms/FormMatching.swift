import Foundation
import FoundationModels
import os

/// One field of a form, from a PDF or a web page, described the same way so one matcher serves both.
nonisolated struct FieldDescriptor: Identifiable, Hashable, Sendable {
    /// The PDF field name, or the token Dossier gave a web field.
    var id: String
    /// Stable across visits, for remembering matches per website: the field's name or id, else its label.
    var memoryKey: String
    var label: String
    /// Section headings above the field: "Spouse information", "Previous addresses".
    var context: String = ""
    var name: String = ""
    /// The site's own autofill hint, such as `family-name` or `bday-month`.
    var autocomplete: String?
    /// text, date, email, tel, number, select, radio or textarea.
    var inputType: String = "text"
    /// The choices of a dropdown or radio group.
    var options: [String] = []
    var placeholder: String?
    var maxLength: Int?
    /// What's in the field already.
    var currentValue: String = ""

    /// Everything that describes the field, as lowercase words.
    var text: String {
        " " + [FormFieldMatcher.words(name), FormFieldMatcher.words(label), FormFieldMatcher.words(placeholder ?? "")].joined(separator: " ") + " "
    }

    var contextText: String { " " + FormFieldMatcher.words(context) + " " }
}

/// Day, month or year, for a date split over several fields.
nonisolated enum DatePart: String, Codable, Sendable {
    case day, month, year
}

/// Which value a field wants, before choosing a row.
nonisolated struct FieldMatch: Hashable, Codable, Sendable {
    enum Source: String, Codable, Sendable { case memory, autocomplete, rule, model, you }

    var slot: String
    var part: DatePart?
    var source: Source
}

/// What a page or PDF gets: each field's entry, and how many rows of repeated sections are left over.
nonisolated struct FormAssignment: Sendable {
    /// Field id → entry id.
    var entries: [String: String]
    var matches: [String: FieldMatch]
    /// "Previous addresses" → 2: rows the form has no room for yet ("Add another" on the site).
    var remaining: [String: Int]
}

nonisolated enum FormMatcher {
    // MARK: Matching

    /// The value a field wants, from what's known without the model.
    static func match(_ field: FieldDescriptor, slots: Set<String>, memory: [String: String] = [:]) -> FieldMatch? {
        func found(_ slot: String?, _ source: FieldMatch.Source) -> FieldMatch? {
            guard let slot, slots.contains(slot) else { return nil }
            return FieldMatch(slot: slot, part: datePart(field), source: source)
        }
        if let remembered = memory[field.memoryKey] {
            // You said this field takes none of your values.
            if remembered.isEmpty { return nil }
            if let match = found(remembered, .memory) { return match }
        }
        if let hint = field.autocomplete, let match = found(autocompleteSlot(hint, field: field), .autocomplete) { return match }
        if let match = found(ruleSlot(field, slots: slots), .rule) { return match }
        return nil
    }

    /// The site's autofill hint, such as `given-name` or `bday-month`.
    static func autocompleteSlot(_ hint: String, field: FieldDescriptor) -> String? {
        let tokens = hint.lowercased().split(separator: " ").map(String.init)
        guard let token = tokens.last(where: { !["on", "off", "shipping", "billing", "home", "work", "mobile"].contains($0) && !$0.hasPrefix("section-") }) else { return nil }
        switch token {
        case "family-name": return "you.familyName"
        case "given-name": return "you.givenName"
        case "additional-name": return "you.middleName"
        case "name": return "you.fullName"
        case "bday", "bday-day", "bday-month", "bday-year": return "you.dateOfBirth"
        case "sex", "gender": return "you.sex"
        case "street-address", "address-line1": return "address.street"
        case "address-line2": return "address.unit"
        case "address-level2": return "address.city"
        case "address-level1": return "address.state"
        case "postal-code": return "address.postalCode"
        case "country", "country-name": return "address.country"
        case "email": return "you.detail.email"
        case "tel", "tel-national": return "you.detail.phone"
        default: return nil
        }
    }

    /// Whose value the field asks for, from its own words and its section's.
    static func relation(of field: FieldDescriptor) -> Relation? {
        let own = field.text, section = field.contextText
        func mentions(_ words: [String], in text: String) -> Bool { words.contains { text.contains(" \($0) ") || text.contains(" \($0)s ") } }
        let table: [(Relation, [String])] = [
            (.father, ["father", "father s"]), (.mother, ["mother", "mother s"]),
            (.spouse, ["spouse", "husband", "wife", "spouse s"]), (.child, ["child", "son", "daughter", "children"]),
            (.sibling, ["sibling", "brother", "sister"]),
        ]
        // The field's own words win over its section's: "Father's name" in a "Parents" section.
        for text in [own, section] {
            if let found = table.first(where: { mentions($0.1, in: text) }) { return found.0 }
        }
        return nil
    }

    /// Which history list a field belongs to, if any.
    enum History: String { case previousAddress, trip, usArrival }

    static func history(of field: FieldDescriptor) -> History? {
        let text = field.contextText + field.text
        if ["previous address", "prior address", "former address", "address history", "previous residence", "where you have lived", "residence history"].contains(where: text.contains) { return .previousAddress }
        if ["trips outside", "travel outside", "time outside", "absence", "trips abroad", "trips taken"].contains(where: text.contains) { return .trip }
        if ["previous visit", "previous u s", "prior visit", "last five visits", "u s visit"].contains(where: text.contains) { return .usArrival }
        return nil
    }

    /// The kind of value, by the field's words: ordered specific before general.
    private static let kinds: [(kind: String, all: [String], none: [String])] = [
        ("alienNumber", ["a number"], []), ("alienNumber", ["alien"], []), ("alienNumber", ["uscis number"], ["online"]),
        ("passportIssuingCountry", ["passport", "issu", "country"], []), ("passportIssuingCountry", ["passport", "authority"], []),
        ("passportIssue", ["passport", "issu", "date"], []),
        ("passportExpiry", ["passport", "expir"], []),
        ("passportNumber", ["passport", "number"], ["country", "book"]), ("passportNumber", ["passport", "no"], ["country"]),
        ("i94Number", ["i 94"], []), ("i94Number", ["arrival departure record"], []),
        ("licenceNumber", ["driver", "licen", "number"], []),
        ("countryOfBirth", ["country of birth"], []), ("countryOfBirth", ["birth country"], []),
        ("cityOfBirth", ["city of birth"], []), ("cityOfBirth", ["town of birth"], []), ("cityOfBirth", ["birth city"], []),
        ("placeOfBirth", ["place of birth"], []), ("placeOfBirth", ["city", "birth"], []), ("placeOfBirth", ["birthplace"], []),
        ("dateOfBirth", ["date of birth"], []), ("dateOfBirth", ["dob"], []), ("dateOfBirth", ["birth date"], []), ("dateOfBirth", ["birthdate"], []),
        ("nationality", ["citizenship"], []), ("nationality", ["nationality"], []),
        ("departure", ["date", "left"], []), ("departure", ["departure date"], []), ("departure", ["date of departure"], []),
        ("return", ["date", "return"], []),
        ("arrival", ["last arrival"], ["place", "status"]), ("arrival", ["date arrived"], []), ("arrival", ["arrival date"], []), ("arrival", ["date of arrival"], []),
        ("days", ["days"], ["date"]), ("days", ["length of stay"], []),
        ("destination", ["destination"], []), ("destination", ["countries", "travel"], []),
        ("fullName", ["full name"], []),
        ("familyName", ["family name"], ["other"]), ("familyName", ["last name"], ["other"]), ("familyName", ["surname"], ["other"]),
        ("givenNames", ["given names"], ["other"]), ("givenName", ["given name"], ["other"]), ("givenName", ["first name"], ["other"]),
        ("middleName", ["middle name"], ["other"]),
        ("from", ["date from"], []), ("from", ["from date"], []), ("from", ["moved in"], []), ("from", ["since"], []),
        ("to", ["date to"], []), ("to", ["to date"], []), ("to", ["moved out"], []),
        ("unit", ["apt"], []), ("unit", ["ste flr"], []), ("unit", ["unit"], []), ("unit", ["address line 2"], []), ("unit", ["suite"], []),
        ("street", ["street"], []), ("street", ["address line 1"], []),
        ("city", ["city"], []), ("city", ["town"], []),
        ("postalCode", ["zip"], []), ("postalCode", ["postal code"], []), ("postalCode", ["postcode"], []),
        ("state", ["state"], ["united states", "statement", "status"]), ("state", ["province"], []),
        ("country", ["country"], []),
        ("sex", ["sex"], []), ("sex", ["gender"], []),
        ("email", ["email"], []), ("email", ["e mail"], []),
        ("phone", ["phone"], []), ("phone", ["telephone"], []), ("phone", ["mobile"], []),
        ("fullName", ["name"], ["user", "company", "employer", "school", "file", "street", "city", "country", "state"]),
    ]

    static func kind(of field: FieldDescriptor) -> String? {
        let text = field.text
        for rule in kinds where rule.all.allSatisfy({ text.contains(" " + $0) }) && !rule.none.contains(where: { text.contains($0) }) {
            return rule.kind
        }
        return nil
    }

    /// The slot for a kind of value, given whose and which list.
    static func ruleSlot(_ field: FieldDescriptor, slots: Set<String>) -> String? {
        let kind = kind(of: field)
        if let relation = relation(of: field) {
            let prefix = "family.\(relation.rawValue)"
            let personal = ["familyName": "familyName", "givenName": "givenName", "givenNames": "givenName", "middleName": "givenName", "fullName": "fullName",
                            "dateOfBirth": "dateOfBirth", "placeOfBirth": "placeOfBirth", "cityOfBirth": "placeOfBirth",
                            "countryOfBirth": "placeOfBirth", "nationality": "nationality"]
            if let kind, let name = personal[kind] { return "\(prefix).\(name)" }
            return detailSlot(field, prefix: "\(prefix).detail.", slots: slots)
        }
        switch history(of: field) {
        case .previousAddress:
            if let kind, ["street", "unit", "city", "state", "postalCode", "country", "from", "to"].contains(kind) { return "previousAddress.\(kind)" }
            if field.text.contains(" address ") { return "previousAddress.full" }
            return nil
        case .trip:
            switch kind {
            case "departure": return "trip.departure"
            case "return", "arrival": return "trip.return"
            case "days": return "trip.days"
            case "destination", "country": return "trip.destination"
            default: return nil
            }
        case .usArrival:
            switch kind {
            case "arrival", "from": return "usArrival.date"
            default: return nil
            }
        case nil: break
        }
        guard let kind else { return detailSlot(field, prefix: "you.detail.", slots: slots) }
        switch kind {
        case "alienNumber": return "you.alienNumber"
        case "passportNumber": return "passport.number"
        case "passportExpiry": return "passport.expiryDate"
        case "passportIssue": return "passport.issueDate"
        case "passportIssuingCountry": return "passport.issuingCountry"
        case "i94Number": return "i94.number"
        case "licenceNumber": return "licence.number"
        case "arrival": return "usArrival.date"
        case "departure", "return", "days", "destination", "to": return nil
        case "from": return "address.from"
        case "street", "unit", "city", "state", "postalCode", "country": return "address.\(kind)"
        case "email", "phone": return "you.detail.\(kind)"
        default: return "you.\(kind)"
        }
    }

    /// A detail you or a relative has, such as "Height" or "Occupation", named by the field.
    static func detailSlot(_ field: FieldDescriptor, prefix: String, slots: Set<String>) -> String? {
        let text = field.text.replacingOccurrences(of: "colour", with: "color")
        return slots
            .filter { $0.hasPrefix(prefix) }
            .sorted { $0.count > $1.count }
            .first { slot in
                let words = slot.dropFirst(prefix.count).split(separator: "-")
                return !words.isEmpty && words.allSatisfy { text.contains(" \($0)") }
            }
    }

    /// Whether the field takes only the day, month or year of a date.
    static func datePart(_ field: FieldDescriptor) -> DatePart? {
        if let hint = field.autocomplete?.lowercased() {
            if hint.hasSuffix("bday-day") { return .day }
            if hint.hasSuffix("bday-month") { return .month }
            if hint.hasSuffix("bday-year") { return .year }
        }
        guard field.inputType != "date" else { return nil }
        let text = field.text
        let options = field.options.map { $0.lowercased() }
        if !options.isEmpty {
            let numbers = options.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if options.contains(where: { $0.hasPrefix("jan") }) && options.contains(where: { $0.hasPrefix("dec") }) { return .month }
            if numbers.count >= 28, numbers.allSatisfy({ (1...31).contains($0) }) { return .day }
            if numbers.count >= 12, numbers.count <= 13, numbers.allSatisfy({ (1...12).contains($0) }) { return .month }
            if numbers.contains(where: { $0 > 1900 }) { return .year }
        }
        // Whole dates say so: "mm/dd/yyyy".
        if text.contains("mm dd yyyy") || text.contains("dd mm yyyy") || text.contains("yyyy mm dd") { return nil }
        if text.contains(" day ") || text.hasSuffix("day ") || text.contains(" dd ") { return .day }
        if text.contains(" month ") || text.contains(" mm ") { return .month }
        if text.contains(" year ") || text.contains(" yyyy ") || field.maxLength == 4 { return .year }
        return nil
    }

    // MARK: Rows

    /// The sections that repeat, with the slot that counts their rows.
    static let repeatedSections: [(name: String, slot: String)] = [
        ("Previous addresses", "previousAddress.street"), ("Trips", "trip.departure"),
        ("Arrivals in the US", "usArrival.date"), ("Children", "family.child.fullName"), ("Siblings", "family.sibling.fullName"),
    ]

    /// Gives each matched field its entry. Repeated sections fill in page order: the first previous-address
    /// fields get the most recent previous address, the next set the one before, and so on. Rows the page
    /// has no room for are counted, so you can add another on the site and fill again.
    static func assign(_ fields: [FieldDescriptor], matches: [String: FieldMatch], catalog: FormCatalog) -> FormAssignment {
        var entries: [String: String] = [:]
        var seen: [String: Int] = [:]
        for field in fields {
            guard let match = matches[field.id] else { continue }
            let rows = catalog.entries(slot: match.slot)
            guard let first = rows.first else { continue }
            if first.row == nil {
                entries[field.id] = first.id
            } else {
                let key = "\(match.slot)|\(match.part?.rawValue ?? "")"
                let index = seen[key, default: 0]
                seen[key] = index + 1
                if index < rows.count { entries[field.id] = rows[index].id }
            }
        }
        var remaining: [String: Int] = [:]
        for section in repeatedSections {
            let available = catalog.entries(slot: section.slot).count
            let onPage = seen["\(section.slot)|", default: 0]
            if onPage > 0, available > onPage { remaining[section.name] = available - onPage }
        }
        return FormAssignment(entries: entries, matches: matches, remaining: remaining)
    }

    // MARK: Values

    /// What will actually be entered: for a dropdown or radio group, the choice that matches.
    static func shown(_ candidates: [String], in field: FieldDescriptor) -> String? {
        guard !field.options.isEmpty else { return candidates.first }
        func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        for candidate in candidates {
            if let option = field.options.first(where: { norm($0) == norm(candidate) }) { return option }
        }
        for candidate in candidates where norm(candidate).count >= 3 {
            if let option = field.options.first(where: { norm($0).count >= 3 && (norm($0).hasPrefix(norm(candidate)) || norm(candidate).hasPrefix(norm($0))) }) { return option }
        }
        return candidates.first
    }

    /// The ways a value can be written into a field, best first: a dropdown takes whichever option matches.
    static func candidates(for value: String, kind: FormValueKind, part: DatePart?, field: FieldDescriptor) -> [String] {
        switch kind {
        case .date:
            guard let date = SimpleDate(iso: value) else { return [value] }
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            let month = months[date.month - 1]
            switch part {
            case .day: return [String(format: "%02d", date.day), String(date.day)]
            case .month: return [String(format: "%02d", date.month), String(date.month), String(month.prefix(3)).uppercased(), String(month.prefix(3)), month, month.uppercased()]
            case .year: return [String(date.year)]
            case nil:
                if field.inputType == "date" { return [date.iso] }
                let hint = FormFieldMatcher.words([field.placeholder ?? "", field.label].joined(separator: " "))
                if hint.contains("dd mmm yyyy") { return [String(format: "%02d-%@-%04d", date.day, String(month.prefix(3)).uppercased(), date.year)] }
                if hint.contains("dd mm yyyy") { return [String(format: "%02d/%02d/%04d", date.day, date.month, date.year)] }
                if hint.contains("yyyy mm dd") { return [date.iso] }
                return [String(format: "%02d/%02d/%04d", date.month, date.day, date.year)]
            }
        case .sex:
            switch value.uppercased().first {
            case "F": return ["F", "Female", "FEMALE", "Woman"]
            case "M": return ["M", "Male", "MALE", "Man"]
            default: return [value, "X", "Unspecified", "Another gender"]
            }
        case .country:
            return [value, value.capitalized]
        case .text, .number:
            return [value]
        }
    }
}

// MARK: Remembering per website

/// Matches you corrected, per website: "this field is my passport number". Only field names and slots are
/// kept, never values.
nonisolated enum FormMemory {
    private static let key = "formFieldMemory"

    static func matches(for site: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key)?[site] as? [String: String]) ?? [:]
    }

    /// Remembers which slot a field takes on a site. Nil means "none of my values", so it's left alone.
    static func remember(_ slot: String?, for field: FieldDescriptor, on site: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var matches = (all[site] as? [String: String]) ?? [:]
        matches[field.memoryKey] = slot ?? ""
        all[site] = matches
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(site: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[site] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: Asking the model

@Generable(description: "Which value, if any, belongs in each form field")
nonisolated struct GeneratedSlotMatches {
    var matches: [GeneratedSlotMatch]
}

@Generable(description: "The value for one form field")
nonisolated struct GeneratedSlotMatch {
    @Guide(description: "The field's number from the list.")
    var field: Int

    @Guide(description: "The number of the value from the list of values, or -1 when none fits.")
    var value: Int
}

/// Matches the fields the rules couldn't. Only the fields' labels and the values' names are sent ("Father’s
/// date of birth"), never a value from the vault.
actor FieldAssistant {
    private let logger = Logger(subsystem: "liziyue.Dossier", category: "Forms")

    func suggest(for fields: [FieldDescriptor], slots: [(slot: String, label: String)], preferPrivateCloud: Bool) async -> [String: FieldMatch] {
        guard !fields.isEmpty, !slots.isEmpty else { return [:] }
        let fieldList = fields.enumerated().map { index, field in
            let section = field.context.isEmpty ? "" : " [section: \(field.context)]"
            let options = field.options.isEmpty ? "" : " [choices: \(field.options.prefix(6).joined(separator: ", "))]"
            return "\(index). \(field.label)\(section)\(options)"
        }.joined(separator: "\n")
        let valueList = slots.enumerated().map { "\($0.offset). \($0.element.label)" }.joined(separator: "\n")
        let instructions = """
            You match the fields of a government, travel or rental application form to the applicant's saved \
            values. Match a field only when it clearly asks for that value. Fields about another person (spouse, \
            parent, child) match only that person's values. Signatures, yes/no eligibility questions, \
            declarations, passwords and fields about the preparer or interpreter get -1.
            """
        let prompt = "Fields:\n\(fieldList)\n\nValues:\n\(valueList)"
        do {
            let session: LanguageModelSession
            let pcc = PrivateCloudComputeLanguageModel()
            if preferPrivateCloud, pcc.isAvailable, !pcc.quotaUsage.isLimitReached {
                session = LanguageModelSession(model: pcc, instructions: instructions)
            } else if SystemLanguageModel.default.isAvailable {
                session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            } else {
                return [:]
            }
            let response = try await session.respond(to: prompt, generating: GeneratedSlotMatches.self, options: GenerationOptions(samplingMode: .greedy))
            var result: [String: FieldMatch] = [:]
            for match in response.content.matches where fields.indices.contains(match.field) && slots.indices.contains(match.value) {
                let field = fields[match.field]
                result[field.id] = FieldMatch(slot: slots[match.value].slot, part: FormMatcher.datePart(field), source: .model)
            }
            return result
        } catch {
            logger.error("Field matching failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }
}
