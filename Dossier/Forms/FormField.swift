import Foundation

/// One fillable text field in a PDF form.
nonisolated struct FormFieldInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    /// The PDF field name, such as `form1[0].#subform[0].Pt2Line1a_FamilyName[0]`.
    var name: String
    /// The field's tooltip (`/TU`), which on USCIS forms is the printed question.
    var tooltip: String?
    var page: Int

    /// The field as the matcher sees it. The tooltip is the label when there is one.
    var descriptor: FieldDescriptor {
        let last = name.components(separatedBy: ".").last ?? name
        return FieldDescriptor(id: name, memoryKey: name, label: displayName, name: last.replacingOccurrences(of: "[0]", with: ""))
    }

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

/// Turns field names into words.
nonisolated enum FormFieldMatcher {
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
