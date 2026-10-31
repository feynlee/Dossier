import CoreGraphics
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
        find(candidates: joinFragments(lines.map(clean).filter(isZoneLike)))
    }

    /// Like `find(in:)`, using where each line is on the page: OCR often splits a zone's line into pieces at its
    /// long runs of `<`, and the pieces of one line sit side by side. Boxes are top-left based, 0–1.
    static func find(in lines: [String], boxes: [CGRect]) -> MRZResult? {
        guard boxes.count == lines.count else { return find(in: lines) }
        if let exact = find(in: lines), exact.isValid { return exact }
        var rows: [(midY: CGFloat, height: CGFloat, parts: [(x: CGFloat, text: String)])] = []
        for (line, box) in zip(lines, boxes) {
            let text = clean(line)
            guard isZoneLike(text) else { continue }
            if let index = rows.firstIndex(where: { abs($0.midY - box.midY) < max($0.height, box.height) * 0.6 }) {
                rows[index].parts.append((box.minX, text))
            } else {
                rows.append((box.midY, box.height, [(box.minX, text)]))
            }
        }
        let joined = rows.sorted { $0.midY < $1.midY }.map { row in row.parts.sorted { $0.x < $1.x }.map(\.text).joined() }
        let byRow = find(candidates: joined)
        if let byRow, byRow.isValid { return byRow }
        return byRow ?? find(in: lines)
    }

    /// The first zone on any page, preferring one whose check digits pass.
    static func find(in pages: [ReadPage]) -> MRZResult? {
        let found = pages.compactMap { find(in: $0.lines, boxes: $0.boxes) }
        return found.first(where: \.isValid) ?? found.first
    }

    /// Tries every run of consecutive zone lines as a passport zone (2 × 44) or a card zone (3 × 30), fitting
    /// lines whose `<` runs OCR shortened or lengthened. Prefers a zone whose check digits pass.
    static func find(candidates lines: [String]) -> MRZResult? {
        var fallback: MRZResult?
        for index in lines.indices {
            let line = lines[index]
            if line.first == "P", index + 1 < lines.count,
               let first = fit(line, to: 44), let second = fit(lines[index + 1], to: 44),
               let result = parseTD3(first, second) {
                if result.isValid { return result }
                if fallback == nil || result.failedChecks.count < fallback!.failedChecks.count { fallback = result }
            }
            if let code = line.first, "IAC".contains(code), index + 2 < lines.count,
               let first = fit(line, to: 30), let second = fit(lines[index + 1], to: 30), let third = fit(lines[index + 2], to: 30),
               let result = parseTD1(first, second, third) {
                if result.isValid { return result }
                if fallback == nil || result.failedChecks.count < fallback!.failedChecks.count { fallback = result }
            }
        }
        // A zone whose every check fails is more likely text that happens to contain `<` than a zone.
        guard let fallback, fallback.failedChecks.count < 3 else { return nil }
        return fallback
    }

    /// Lines that look like part of a zone: any `<`, or a long run of capitals and digits.
    static func isZoneLike(_ text: String) -> Bool {
        !text.isEmpty && (text.contains("<") || text.count >= 25 && text.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    /// Joins the pieces OCR split off a line when there are no boxes to place them. A piece of only `<` is
    /// dropped (`fit` grows the line's filler back); a short piece ending in check digits joins the line before it.
    static func joinFragments(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            let isPiece = line.count < 12 && line.filter { $0 != "<" }.count <= 3
            if isPiece, !line.contains(where: { $0 != "<" }) { continue }
            if isPiece, !out.isEmpty { out[out.count - 1] += line } else { out.append(line) }
        }
        return out
    }

    /// Makes a line exactly `length` long by growing or shrinking its longest run of `<`, where OCR loses count.
    static func fit(_ line: String, to length: Int) -> String? {
        if line.count == length { return line }
        guard abs(line.count - length) <= 16 else { return nil }
        let characters = Array(line)
        var best: Range<Int>?
        var start: Int?
        for index in 0...characters.count {
            let isFiller = index < characters.count && characters[index] == "<"
            if isFiller, start == nil { start = index }
            if !isFiller, let begin = start {
                if best == nil || index - begin >= best!.count { best = begin..<index }
                start = nil
            }
        }
        guard let run = best else {
            return line.count < length ? line + String(repeating: "<", count: length - line.count) : nil
        }
        let newCount = run.count + length - line.count
        guard newCount >= 0 else { return nil }
        return String(characters[..<run.lowerBound]) + String(repeating: "<", count: newCount) + String(characters[run.upperBound...])
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
            issuingCountry: letters(trimFiller(String(l1[2..<5]))),
            documentNumber: trimFiller(documentNumber),
            nationality: letters(trimFiller(String(l2[10..<13]))),
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

        var documentNumber = String(l1[5..<14])
        let birth = digits(l2[0..<6])
        let expiry = digits(l2[8..<14])
        var failed: [String] = []
        // ICAO's rule for numbers longer than nine characters (US green cards and EADs): `<` where the check
        // digit goes, then the rest of the number and its check digit in the optional data.
        let rest = l1[15..<30].prefix { $0 != "<" }
        if l1[14] == "<", rest.count >= 2 {
            documentNumber += String(rest.dropLast())
            check(documentNumber, rest.last!, "document number", into: &failed)
        } else {
            check(documentNumber, l1[14], "document number", into: &failed)
        }
        check(birth, l2[6], "date of birth", into: &failed)
        check(expiry, l2[14], "expiry date", into: &failed)
        let composite = String(l1[5..<30]) + birth + String(l2[6]) + expiry + String(l2[14]) + String(l2[18..<29])
        check(composite, l2[29], "composite", into: &failed)

        let (surname, given) = names(line3)
        return MRZResult(
            format: .td1,
            documentCode: trimFiller(String(l1[0..<2])),
            issuingCountry: letters(trimFiller(String(l1[2..<5]))),
            documentNumber: trimFiller(documentNumber),
            nationality: letters(trimFiller(String(l2[15..<18]))),
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

    /// Country codes are letters: undo digit-for-letter swaps such as UT0 for UTO.
    private static func letters(_ value: String) -> String {
        String(value.map { character -> Character in
            switch character {
            case "0": return "O"
            case "1": return "I"
            case "2": return "Z"
            case "5": return "S"
            case "8": return "B"
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
