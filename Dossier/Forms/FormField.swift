import Foundation

/// A value Dossier can put into a form field. Several are derived from facts: a street line from an address,
/// the first given name from "Anna Maria", the last arrival from the I-94 history.
nonisolated enum FormValue: String, CaseIterable, Codable, Sendable {
    case familyName
    case givenName
    case middleName
    case dateOfBirth
    case placeOfBirth
    case sex
    case nationality
    case passportNumber
    case passportExpiry
    case alienNumber
    case i94Number
    case lastArrivalDate
    case licenceNumber
    case street
    case unit
    case city
    case state
    case postalCode

    var label: String {
        switch self {
        case .familyName: "Family name"
        case .givenName: "Given name"
        case .middleName: "Middle name"
        case .dateOfBirth: "Date of birth"
        case .placeOfBirth: "Place of birth"
        case .sex: "Sex"
        case .nationality: "Country of citizenship"
        case .passportNumber: "Passport number"
        case .passportExpiry: "Passport expiry"
        case .alienNumber: "A-Number"
        case .i94Number: "I-94 number"
        case .lastArrivalDate: "Date of last arrival"
        case .licenceNumber: "Driver’s licence number"
        case .street: "Street"
        case .unit: "Apt, suite or floor"
        case .city: "City or town"
        case .state: "State"
        case .postalCode: "ZIP code"
        }
    }

    var isSensitive: Bool {
        switch self {
        case .passportNumber, .alienNumber, .i94Number, .licenceNumber: true
        default: false
        }
    }

    var isDate: Bool {
        switch self {
        case .dateOfBirth, .passportExpiry, .lastArrivalDate: true
        default: false
        }
    }
}

/// One fillable text field in a PDF form.
nonisolated struct FormFieldInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    /// The PDF field name, such as `form1[0].#subform[0].Pt2Line1a_FamilyName[0]`.
    var name: String
    /// The field's tooltip (`/TU`), which on USCIS forms is the printed question.
    var tooltip: String?
    var page: Int

    /// The field as readable words: "pt2 line1a family name" plus the tooltip.
    var searchText: String {
        FormFieldMatcher.words(name.components(separatedBy: ".").last ?? name) + " " + FormFieldMatcher.words(tooltip ?? "")
    }

    /// A short, human label for the mapping list.
    var displayName: String {
        if let tooltip, !tooltip.isEmpty { return tooltip }
        let last = name.components(separatedBy: ".").last ?? name
        return FormFieldMatcher.words(last.replacingOccurrences(of: "[0]", with: "")).capitalized
    }
}

/// Maps form fields to values by their names and tooltips, without the model.
nonisolated enum FormFieldMatcher {
    /// Ordered: specific phrases before general ones ("place of birth" before "city").
    private static let rules: [(value: FormValue, all: [String], none: [String])] = [
        (.alienNumber, ["a number"], []),
        (.alienNumber, ["alien"], []),
        (.alienNumber, ["uscis number"], ["online"]),
        (.passportExpiry, ["passport", "expir"], []),
        (.passportNumber, ["passport", "number"], ["country"]),
        (.passportNumber, ["passport", "no"], ["country"]),
        (.i94Number, ["i 94"], []),
        (.i94Number, ["arrival departure record"], []),
        (.lastArrivalDate, ["last arrival"], ["place", "status"]),
        (.licenceNumber, ["driver", "licen", "number"], []),
        (.placeOfBirth, ["place of birth"], []),
        (.placeOfBirth, ["city", "birth"], []),
        (.dateOfBirth, ["date of birth"], []),
        (.dateOfBirth, ["dob"], []),
        (.dateOfBirth, ["birth date"], []),
        (.nationality, ["citizenship"], []),
        (.nationality, ["nationality"], []),
        (.familyName, ["family name"], ["other"]),
        (.familyName, ["last name"], ["other"]),
        (.familyName, ["surname"], []),
        (.givenName, ["given name"], ["other"]),
        (.givenName, ["first name"], ["other"]),
        (.middleName, ["middle name"], ["other"]),
        (.unit, ["apt"], []),
        (.unit, ["ste flr"], []),
        (.unit, ["unit"], []),
        (.street, ["street"], []),
        (.street, ["address line 1"], []),
        (.city, ["city"], []),
        (.city, ["town"], []),
        (.postalCode, ["zip"], []),
        (.postalCode, ["postal code"], []),
        (.state, ["state"], ["united states", "statement", "status"]),
        (.sex, ["sex"], []),
        (.sex, ["gender"], []),
    ]

    static func match(_ field: FormFieldInfo) -> FormValue? {
        let text = " " + field.searchText + " "
        for rule in rules where rule.all.allSatisfy({ text.contains(" " + $0) }) && !rule.none.contains(where: { text.contains($0) }) {
            return rule.value
        }
        return nil
    }

    /// "Pt2Line1a_FamilyName[0]" → "pt2 line1a family name".
    static func words(_ value: String) -> String {
        var result = ""
        var previous: Character?
        for character in value {
            if let previous, character.isUppercase, previous.isLowercase { result.append(" ") }
            if character == "-" { result.append(" "); previous = character; continue }
            result.append(character.isLetter || character.isNumber ? character : " ")
            previous = character
        }
        return result.lowercased().split(separator: " ").joined(separator: " ")
    }
}

/// Splits "412 Alder St, Apt 3B, Seattle, WA 98101" into the parts forms ask for.
nonisolated struct AddressParts: Equatable, Sendable {
    var street: String
    var unit: String?
    var city: String?
    var state: String?
    var postalCode: String?

    init(street: String, unit: String? = nil, city: String? = nil, state: String? = nil, postalCode: String? = nil) {
        self.street = street
        self.unit = unit
        self.city = city
        self.state = state
        self.postalCode = postalCode
    }

    init(_ address: String) {
        var parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        street = parts.isEmpty ? address : parts.removeFirst()

        if let last = parts.last {
            let tokens = last.split(separator: " ").map(String.init)
            if let zip = tokens.last, zip.prefix(5).allSatisfy(\.isNumber), zip.count >= 5 {
                postalCode = String(zip.prefix(5))
                if tokens.count >= 2 { state = tokens[tokens.count - 2] }
                parts.removeLast()
            } else if tokens.count == 1, last.count == 2 {
                state = last
                parts.removeLast()
            }
        }
        if let unitIndex = parts.firstIndex(where: { AddressParts.isUnit($0) }) {
            unit = AddressParts.unitNumber(parts.remove(at: unitIndex))
        } else if let range = street.range(of: #"\s(apt|unit|ste|suite|#)\.?\s*\S+$"#, options: [.regularExpression, .caseInsensitive]) {
            unit = AddressParts.unitNumber(String(street[range]).trimmingCharacters(in: .whitespaces))
            street = String(street[..<range.lowerBound])
        }
        city = parts.last
    }

    private static func isUnit(_ part: String) -> Bool {
        part.range(of: #"^(apt|unit|ste|suite|#)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Apt 3B" → "3B": the form has its own Apt/Ste/Flr checkbox.
    private static func unitNumber(_ part: String) -> String {
        part.replacingOccurrences(of: #"^(apt|unit|ste|suite|#)\.?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
}

nonisolated enum FormDateStyle: Sendable {
    case monthDayYear
    case dayMonthYear
    case iso

    /// US government forms use MM/DD/YYYY unless the field says otherwise.
    static func style(for field: FormFieldInfo) -> FormDateStyle {
        let text = field.searchText
        if text.contains("yyyy mm dd") { return .iso }
        if text.contains("dd mm yyyy") { return .dayMonthYear }
        return .monthDayYear
    }

    func format(_ date: SimpleDate) -> String {
        switch self {
        case .monthDayYear: String(format: "%02d/%02d/%04d", date.month, date.day, date.year)
        case .dayMonthYear: String(format: "%02d/%02d/%04d", date.day, date.month, date.year)
        case .iso: date.iso
        }
    }
}
