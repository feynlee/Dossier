import CoreGraphics
import Foundation

/// Reads the facts a card or form prints under fixed labels straight from OCR, where the language model guesses
/// wrong (seen in testing): a licence's three dates come out of OCR as a block after "3 DOB", "4a ISS" and
/// "4b EXP", and the on-device model gave the birth date as the issue date or swapped issue and expiry; it never
/// found the USCIS number, receipt number or I-94 number. Each label's value is the line printed beside it or
/// just below it.
nonisolated enum CardFieldParser {
    struct Found: Equatable {
        var key: FactKey
        var value: String
        var page: Int
    }

    struct Line {
        var text: String
        var box: CGRect
        var page: Int
    }

    static func fields(in pages: [ReadPage], kind: DocumentKind) -> [Found] {
        let lines = pages.enumerated().flatMap { index, page in
            zip(page.lines, page.boxes.count == page.lines.count ? page.boxes : Array(repeating: .zero, count: page.lines.count))
                .map { Line(text: $0, box: $1, page: index + 1) }
        }
        var found: [Found] = []
        func add(_ key: FactKey, _ value: String?, page: Int) {
            guard let value, !value.isEmpty, !found.contains(where: { $0.key == key }) else { return }
            found.append(Found(key: key, value: value, page: page))
        }

        switch kind {
        case .driversLicense, .stateID:
            for (pattern, key) in [(#"\bDOB\b"#, FactKey.dateOfBirth), (#"\bISS\b"#, .issueDate), (#"\bEXP\b"#, .expiryDate)] {
                if let hit = value(after: pattern, in: lines, matching: date) { add(key, hit.0, page: hit.1) }
            }
            if let hit = value(after: #"\b(DLN|LIC|DL NO|LICENSE NO)\b"#, in: lines, matching: { text in
                let token = text.split(separator: " ").last.map(String.init) ?? text
                return token.count >= 5 && token.contains(where: \.isNumber) ? token : nil
            }) { add(.documentNumber, hit.0, page: hit.1) }
        case .greenCard, .employmentAuthorization:
            if let hit = value(after: #"(USCIS\s?#|\bA\s?#|A-NUMBER|ALIEN)"#, in: lines, matching: aNumber) { add(.alienNumber, hit.0, page: hit.1) }
        case .uscisNotice:
            if let hit = value(after: #"(\bA\s?#|A-NUMBER|USCIS\s?#|ALIEN)"#, in: lines, matching: aNumber) { add(.alienNumber, hit.0, page: hit.1) }
            for line in lines {
                if let match = line.text.uppercased().firstMatch(of: #/\b(IOE|MSC|EAC|WAC|LIN|SRC|NBC|YSC)\s?(\d{10})\b/#) {
                    add(.receiptNumber, String(match.1) + String(match.2), page: line.page)
                }
                // OCR often reads the I as a one: "1-485 Application to Register…".
                if let match = line.text.uppercased().firstMatch(of: #/\b(?:I-?|[1L]-)\s?(\d{3})\b(?!-)/#), !["797"].contains(String(match.1)) {
                    add(.formType, "I-" + String(match.1), page: line.page)
                }
            }
        case .i94:
            if let hit = value(after: #"(I-?94 RECORD|ADMISSION.*NUMBER|RECORD NUMBER)"#, in: lines, matching: { text in
                text.firstMatch(of: #/\b(\d{11})\b/#).map { String($0.1) }
            }) { add(.i94Number, hit.0, page: hit.1) }
        default:
            break
        }
        return found
    }

    /// Details printed under licence labels: height and eye colour.
    static func details(in pages: [ReadPage], kind: DocumentKind) -> [(label: String, value: String, page: Int)] {
        guard kind == .driversLicense || kind == .stateID else { return [] }
        let lines = pages.enumerated().flatMap { index, page in
            zip(page.lines, page.boxes.count == page.lines.count ? page.boxes : Array(repeating: .zero, count: page.lines.count))
                .map { Line(text: $0, box: $1, page: index + 1) }
        }
        var out: [(String, String, Int)] = []
        if let hit = value(after: #"\bHGT\b"#, in: lines, matching: { $0.contains("'") || $0.contains("\"") || $0.contains("-") ? $0.trimmingCharacters(in: .whitespaces) : nil }) {
            out.append(("Height", hit.0, hit.1))
        }
        if let hit = value(after: #"\bEYES\b"#, in: lines, matching: { text in
            let word = text.trimmingCharacters(in: .whitespaces).uppercased()
            return ["BRN", "BLU", "GRN", "HAZ", "GRY", "BLK", "BRO", "BLUE", "BROWN", "GREEN", "HAZEL", "GRAY", "GREY", "BLACK"].contains(word) ? word : nil
        }) {
            out.append(("Eye colour", hit.0, hit.1))
        }
        return out
    }

    // MARK: Values

    static func date(_ text: String) -> String? {
        Verifier.looseDate(text, order: .monthFirst)?.iso
    }

    /// A USCIS number: nine digits (or eight), with or without an A and dashes.
    static func aNumber(_ text: String) -> String? {
        guard let match = text.uppercased().firstMatch(of: #/\bA?\s?-?(\d{3})-?(\d{3})-?(\d{3})\b/#) else { return nil }
        return "\(match.1)-\(match.2)-\(match.3)"
    }

    /// The value for a label: on the label's own line after it, else the nearest line beside it to the right,
    /// else the nearest line just below it that starts at about the same place.
    static func value(after label: String, in lines: [Line], matching parse: (String) -> String?) -> (String, Int)? {
        guard let regex = try? Regex(label).ignoresCase() else { return nil }
        for line in lines {
            guard let match = line.text.firstMatch(of: regex) else { continue }
            let rest = String(line.text[match.range.upperBound...])
            if let value = parse(rest) { return (value, line.page) }
            guard line.box != .zero else { continue }
            let others = lines.filter { $0.page == line.page && $0.box != line.box }
            let beside = others.filter { abs($0.box.midY - line.box.midY) < line.box.height * 0.6 && $0.box.minX > line.box.minX }
                .sorted { $0.box.minX < $1.box.minX }
            if let near = beside.first, let value = parse(near.text) { return (value, line.page) }
            let below = others.filter { other in
                other.box.minY > line.box.minY && other.box.minY - line.box.maxY < line.box.height * 3
                    && abs(other.box.minX - line.box.minX) < 0.04
            }.sorted { $0.box.minY < $1.box.minY }
            if let near = below.first, let value = parse(near.text) { return (value, line.page) }
        }
        return nil
    }

    // MARK: Applying

    /// The reading with the label-read facts in place of the model's: they are what the page prints next to
    /// the label, so they win where the two differ. Details the model missed are added.
    static func apply(to reading: DocumentReading, pages: [ReadPage]) -> DocumentReading {
        guard let kind = DocumentKind(rawValue: reading.kind) else { return reading }
        var reading = reading
        for found in fields(in: pages, kind: kind) {
            reading.fields.removeAll { $0.key == found.key.rawValue }
            reading.fields.append(ReadField(key: found.key.rawValue, value: found.value, page: found.page, confidence: "high"))
        }
        for detail in details(in: pages, kind: kind) where !reading.details.contains(where: { $0.person == "holder" && $0.label.lowercased() == detail.label.lowercased() }) {
            reading.details.append(ReadDetail(person: "holder", personName: "", label: detail.label, value: detail.value, page: detail.page, confidence: "high", isNumber: "no"))
        }
        return reading
    }
}
