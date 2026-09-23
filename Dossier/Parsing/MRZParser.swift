import Foundation

/// The machine-readable zone of a passport (TD3) or ID card such as a green card or EAD (TD1).
nonisolated struct MRZResult: Equatable, Sendable {
    enum Format: String, Sendable { case td1, td3 }

    var format: Format
    var documentCode: String
    var issuingCountry: String
    var documentNumber: String
    var nationality: String
    var dateOfBirth: SimpleDate?
    var sex: String
    var expiryDate: SimpleDate?
    var surname: String
    var givenNames: String
    /// Names of the check digits that failed; empty when the zone is internally consistent.
    var failedChecks: [String]

    var isValid: Bool { failedChecks.isEmpty }
}

/// Parses ICAO 9303 machine-readable zones out of OCR lines and validates their check digits. This is the
/// deterministic cross-check for what Private Cloud Compute reads off passports and cards.
nonisolated enum MRZParser {
    /// Finds and parses the first TD3 or TD1 zone in OCR output. Lines may contain OCR noise such as
    /// spaces or `«` in place of `<`.
    static func find(in lines: [String]) -> MRZResult? {
        let cleaned = lines.map(clean).filter { $0.contains("<") }
        for index in cleaned.indices {
            let line = cleaned[index]
            if line.count == 44, index + 1 < cleaned.count, cleaned[index + 1].count == 44,
               let result = parseTD3(line, cleaned[index + 1]) {
                return result
            }
            if line.count == 30, index + 2 < cleaned.count, cleaned[index + 1].count == 30, cleaned[index + 2].count == 30,
               let result = parseTD1(line, cleaned[index + 1], cleaned[index + 2]) {
                return result
            }
        }
        return nil
    }

    /// Two 44-character lines: passports.
    static func parseTD3(_ line1: String, _ line2: String) -> MRZResult? {
        let l1 = Array(line1), l2 = Array(line2)
        guard l1.count == 44, l2.count == 44, l1[0] == "P" else { return nil }

        let documentNumber = String(l2[0..<9])
        let birth = digits(l2[13..<19])
        let expiry = digits(l2[21..<27])
        var failed: [String] = []
        check(documentNumber, l2[9], "document number", into: &failed)
        check(birth, l2[19], "date of birth", into: &failed)
        check(expiry, l2[27], "expiry date", into: &failed)
        // The optional-data check digit may be `<` when the field is empty.
        if l2[42] != "<" || l2[28..<42].contains(where: { $0 != "<" }) {
            check(String(l2[28..<42]), l2[42], "personal number", into: &failed)
        }
        let composite = String(l2[0..<10]) + birth + String(l2[19]) + expiry + String(l2[27..<43])
        check(composite, l2[43], "composite", into: &failed)

        let (surname, given) = names(String(l1[5..<44]))
        return MRZResult(
            format: .td3,
            documentCode: trimFiller(String(l1[0..<2])),
            issuingCountry: trimFiller(String(l1[2..<5])),
            documentNumber: trimFiller(documentNumber),
            nationality: trimFiller(String(l2[10..<13])),
            dateOfBirth: SimpleDate(mrz: birth, isBirthDate: true),
            sex: String(l2[20]),
            expiryDate: SimpleDate(mrz: expiry, isBirthDate: false),
            surname: surname,
            givenNames: given,
            failedChecks: failed
        )
    }

    /// Three 30-character lines: ID cards such as US permanent resident cards and EADs.
    static func parseTD1(_ line1: String, _ line2: String, _ line3: String) -> MRZResult? {
        let l1 = Array(line1), l2 = Array(line2)
        guard l1.count == 30, l2.count == 30, line3.count == 30 else { return nil }

        let documentNumber = String(l1[5..<14])
        let birth = digits(l2[0..<6])
        let expiry = digits(l2[8..<14])
        var failed: [String] = []
        check(documentNumber, l1[14], "document number", into: &failed)
        check(birth, l2[6], "date of birth", into: &failed)
        check(expiry, l2[14], "expiry date", into: &failed)
        let composite = String(l1[5..<30]) + birth + String(l2[6]) + expiry + String(l2[14]) + String(l2[18..<29])
        check(composite, l2[29], "composite", into: &failed)

        let (surname, given) = names(line3)
        return MRZResult(
            format: .td1,
            documentCode: trimFiller(String(l1[0..<2])),
            issuingCountry: trimFiller(String(l1[2..<5])),
            documentNumber: trimFiller(documentNumber),
            nationality: trimFiller(String(l2[15..<18])),
            dateOfBirth: SimpleDate(mrz: birth, isBirthDate: true),
            sex: String(l2[7]),
            expiryDate: SimpleDate(mrz: expiry, isBirthDate: false),
            surname: surname,
            givenNames: given,
            failedChecks: failed
        )
    }

    /// ICAO 9303 check digit: weights 7-3-1, digits as themselves, A–Z as 10–35, `<` as 0.
    static func checkDigit(_ value: some StringProtocol) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, character) in value.enumerated() {
            let number: Int
            if let digit = character.wholeNumberValue {
                number = digit
            } else if let ascii = character.asciiValue, (65...90).contains(ascii) {
                number = Int(ascii) - 55
            } else {
                number = 0
            }
            sum += number * weights[index % 3]
        }
        return sum % 10
    }

    // MARK: Helpers

    static func clean(_ line: String) -> String {
        line.uppercased()
            .replacingOccurrences(of: "«", with: "<<")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "<") }
    }

    private static func check(_ value: String, _ digit: Character, _ name: String, into failed: inout [String]) {
        let expected = digit == "<" ? 0 : digit.wholeNumberValue
        if expected != checkDigit(value) { failed.append(name) }
    }

    /// Numeric fields: undo the usual OCR letter-for-digit swaps before validating.
    private static func digits(_ characters: ArraySlice<Character>) -> String {
        String(characters.map { character -> Character in
            switch character {
            case "O", "Q", "D": return "0"
            case "I", "L": return "1"
            case "Z": return "2"
            case "S": return "5"
            case "B": return "8"
            default: return character
            }
        })
    }

    private static func names(_ field: String) -> (surname: String, given: String) {
        let parts = field.components(separatedBy: "<<")
        let surname = parts.first.map(spaced) ?? ""
        let given = parts.dropFirst().map(spaced).filter { !$0.isEmpty }.joined(separator: " ")
        return (surname, given)
    }

    private static func spaced(_ value: String) -> String {
        value.split(separator: "<").joined(separator: " ")
    }

    private static func trimFiller(_ value: String) -> String {
        value.replacingOccurrences(of: "<", with: "")
    }
}
