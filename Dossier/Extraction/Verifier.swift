import Foundation

/// A fact after verification, ready to be sealed and saved.
nonisolated struct VerifiedFact: Equatable, Sendable {
    var key: FactKey
    var value: String
    var page: Int
    var status: FactStatus
    var check: FactCheck
    /// The other reading when the model and a deterministic source disagree.
    var alternate: String?
    /// The OCR line the value was found on.
    var context: String?
    /// Where that line is: 0-based page and line indexes into the OCR output.
    var location: LineLocation?
}

nonisolated struct LineLocation: Equatable, Sendable {
    var page: Int
    var line: Int
}

/// Cross-checks model output against deterministic sources: the MRZ check digits on passports and cards,
/// the PDF417 barcode on licences, and the page's own OCR text. A value goes to review only when there's a
/// reason to doubt it: the model wasn't sure, a checksum-bearing source disagrees, or a number or date can't
/// be found anywhere in the page text. Everything else is accepted.
nonisolated enum Verifier {
    struct Input {
        var key: FactKey
        var value: String
        var page: Int
        /// The model's own rating: false when it said the reading is uncertain.
        var isConfident = true
    }

    static func verify(_ fields: [Input], pages: [[String]], mrz: MRZResult?, license: AAMVARecord?, kind: DocumentKind? = nil) -> [VerifiedFact] {
        let references = references(mrz: mrz, license: license)
        let order = numericDateOrder(in: pages, kind: kind)
        var results: [VerifiedFact] = []
        var seen = Set<FactKey>()

        for field in repaired(fields, pages: pages, order: order) {
            var value = normalizedValue(field.value, for: field.key)
            if field.key.isDate, let date = SimpleDate(iso: value) { value = correctedDate(date, pages: pages, order: order).iso }
            guard !value.isEmpty, seen.insert(field.key).inserted else { continue }
            let location = locate(value, key: field.key, in: pages)
            let context = location.map { pages[$0.page][$0.line] }

            if let reference = references[field.key] {
                // "C1USASRC21904567896" for SRC2190456789: the model kept the zone's code and check digit.
                if field.key == .documentNumber, !matches(value, reference.value, key: field.key),
                   compact(value).contains(compact(reference.value)), compact(reference.value).count >= 6 {
                    value = reference.value
                }
                if matches(value, reference.value, key: field.key) {
                    results.append(VerifiedFact(key: field.key, value: value, page: field.page, status: .verified, check: reference.check, context: context, location: location))
                } else {
                    results.append(VerifiedFact(
                        key: field.key, value: value, page: field.page, status: .needsReview, check: .conflict,
                        alternate: reference.value, context: context, location: location
                    ))
                }
            } else {
                // OCR reliably finds printed numbers and dates, so one it can't find is worth a look. Names and
                // addresses can be read from the image even where OCR fails, so those aren't flagged for it.
                let isUncertain = !field.isConfident || (field.key.isMonospaced && context == nil)
                let check: FactCheck = context != nil ? .pageText : (isUncertain ? .unchecked : .model)
                results.append(VerifiedFact(
                    key: field.key, value: value, page: field.page, status: isUncertain ? .needsReview : .verified,
                    check: check, context: context, location: location
                ))
            }
        }

        // Facts the checksum-bearing source has but the model missed.
        for (key, reference) in references.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }) where !seen.contains(key) {
            let location = locate(reference.value, key: key, in: pages)
            results.append(VerifiedFact(
                key: key, value: reference.value, page: location.map { $0.page + 1 } ?? reference.page, status: .verified,
                check: reference.check, context: location.map { pages[$0.page][$0.line] }, location: location
            ))
        }
        return results.sorted { $0.key.sortOrder < $1.key.sortOrder }
    }

    // MARK: Repairs

    /// Fixes the on-device model's usual slips before checking, each only when the page shows the right reading
    /// (seen in testing): a name spelled the common way ("Eriksen") where the page says ERIKSSON, a licence number
    /// read as the surname, a date left as 12-08-1990, the birth date given as the issue date, and issue and
    /// expiry swapped.
    static func repaired(_ fields: [Input], pages: [[String]], order: DateOrder?) -> [Input] {
        let words = Set(pages.joined().flatMap { line in
            line.uppercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        })
        var out: [Input] = []
        for var field in fields {
            if field.key.isDate, SimpleDate(iso: field.value.trimmingCharacters(in: .whitespaces)) == nil {
                guard let date = looseDate(field.value, order: order) else { continue }
                field.value = date.iso
            }
            if field.key == .surname || field.key == .givenNames {
                // Names have no digits: that's a number the model put in the wrong place.
                if field.value.contains(where: \.isNumber) { continue }
                field.value = field.value.split(separator: " ").map { part in
                    let word = String(part)
                    let upper = word.uppercased()
                    guard upper.count >= 3, !words.contains(upper) else { return word }
                    let close = words.filter { $0.first == upper.first && abs($0.count - upper.count) <= 2 && distance($0, upper) <= 2 }
                    guard let best = close.min(by: { distance($0, upper) < distance($1, upper) }) else { return word }
                    return word == upper ? best : String(best.prefix(1)) + best.dropFirst().lowercased()
                }.joined(separator: " ")
            }
            out.append(field)
        }
        func date(_ key: FactKey) -> SimpleDate? { out.first { $0.key == key }.flatMap { SimpleDate(iso: $0.value) } }
        if let issue = date(.issueDate), let birth = date(.dateOfBirth), issue == birth {
            out.removeAll { $0.key == .issueDate }
        }
        if let issue = date(.issueDate), let expiry = date(.expiryDate), issue > expiry,
           let i = out.firstIndex(where: { $0.key == .issueDate }), let e = out.firstIndex(where: { $0.key == .expiryDate }) {
            out[i].value = expiry.iso
            out[e].value = issue.iso
        }
        return out
    }

    /// 12-08-1990, 08/12/1990, 12.08.1990: in the order the document writes dates, else day first when the first
    /// number can't be a month, else month first. Written-out months are read as they are.
    static func looseDate(_ text: String, order: DateOrder?) -> SimpleDate? {
        if let regex = try? Regex(#"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})\b"#), let match = text.firstMatch(of: regex),
           let a = match.output[1].substring.flatMap({ Int($0) }), let b = match.output[2].substring.flatMap({ Int($0) }),
           let year = match.output[3].substring.flatMap({ Int($0) }) {
            let dayFirst = a > 12 || (b <= 12 && order == .dayFirst)
            return dayFirst ? SimpleDate(year: year, month: b, day: a) : SimpleDate(year: year, month: a, day: b)
        }
        return KnowledgeText.date(text)
    }

    /// Edit distance, for names a letter or two off.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return x.isEmpty ? y.count : y.isEmpty ? x.count : row[y.count]
    }

    // MARK: Details

    /// Checks a detail (height, a parent's name…) like a fact: it needs a look when the model wasn't sure, or
    /// when it's a number or date the page text doesn't show.
    static func verifyDetail(_ value: String, isConfident: Bool, page: Int, pages: [[String]], order: DateOrder? = nil) -> VerifiedFact? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let date = SimpleDate(iso: trimmed).map { correctedDate($0, pages: pages, order: order) }
        let key: FactKey = date != nil ? .issueDate : .detail
        let normalized = date?.iso ?? trimmed
        let location = locate(normalized, key: key, in: pages)
        let context = location.map { pages[$0.page][$0.line] }
        let hasDigits = normalized.contains(where: \.isNumber)
        let isUncertain = !isConfident || ((date != nil || hasDigits) && context == nil)
        let check: FactCheck = context != nil ? .pageText : (isUncertain ? .unchecked : .model)
        return VerifiedFact(
            key: .detail, value: normalized, page: page, status: isUncertain ? .needsReview : .verified,
            check: check, context: context, location: location
        )
    }

    /// Checks something the document records, such as "2019-04-02 · Lot AB123 · King County clinic": each
    /// part with a number or date has to be in the page text, or the model has to have been sure of it.
    static func verifyEntry(_ value: String, isConfident: Bool, page: Int, pages: [[String]], order: DateOrder? = nil) -> VerifiedFact? {
        let parts = value.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let checked = parts.map { part -> (value: String, location: LineLocation?, needsText: Bool) in
            let date = SimpleDate(iso: part).map { correctedDate($0, pages: pages, order: order) }
            let normalized = date?.iso ?? part
            return (normalized, locate(normalized, key: date != nil ? .issueDate : .detail, in: pages), normalized.contains(where: \.isNumber))
        }
        let location = checked.lazy.compactMap(\.location).first
        let context = location.map { pages[$0.page][$0.line] }
        let isUncertain = !isConfident || checked.contains { $0.needsText && $0.location == nil }
        let check: FactCheck = isUncertain ? .unchecked : (context != nil ? .pageText : .model)
        return VerifiedFact(
            key: .detail, value: checked.map(\.value).joined(separator: " · "), page: page,
            status: isUncertain ? .needsReview : .verified, check: check, context: context, location: location
        )
    }

    // MARK: References

    private struct Reference {
        var value: String
        var check: FactCheck
        var page: Int
    }

    private static func references(mrz: MRZResult?, license: AAMVARecord?) -> [FactKey: Reference] {
        var references: [FactKey: Reference] = [:]
        // A zone whose check digits fail is itself misread, so it can't vouch for anything.
        if let mrz, mrz.isValid {
            func add(_ key: FactKey, _ value: String?) {
                if let value, !value.isEmpty { references[key] = Reference(value: value, check: .mrz, page: 1) }
            }
            add(.documentNumber, mrz.documentNumber)
            add(.dateOfBirth, mrz.dateOfBirth?.iso)
            add(.expiryDate, mrz.expiryDate?.iso)
            add(.surname, mrz.surname)
            add(.sex, mrz.sex == "<" ? nil : mrz.sex)
            // Nationality isn't compared: the zone has a code ("UTO") where the page prints a name ("UTOPIAN").
        }
        if let license {
            func add(_ key: FactKey, _ value: String?) {
                if let value, !value.isEmpty { references[key] = Reference(value: value, check: .barcode, page: 1) }
            }
            add(.documentNumber, license.licenseNumber)
            add(.dateOfBirth, license.dateOfBirth?.iso)
            add(.issueDate, license.issueDate?.iso)
            add(.expiryDate, license.expiryDate?.iso)
            add(.surname, license.surname)
        }
        return references
    }

    // MARK: Normalization

    static func normalizedValue(_ value: String, for key: FactKey) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isDate, let date = SimpleDate(iso: trimmed) { return date.iso }
        return trimmed
    }

    static func matches(_ lhs: String, _ rhs: String, key: FactKey) -> Bool {
        if key.isDate { return SimpleDate(iso: lhs) == SimpleDate(iso: rhs) }
        return compact(lhs) == compact(rhs)
    }

    /// Uppercased letters and digits only: "X12 345-678" and "x12345678" compare equal.
    static func compact(_ value: String) -> String {
        String(value.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The OCR line that contains the value, allowing for the many ways documents print dates.
    static func locate(_ value: String, key: FactKey, in pages: [[String]]) -> LineLocation? {
        let candidates: [String]
        if key.isDate, let date = SimpleDate(iso: value) {
            candidates = dateSpellings(date).map(compact)
        } else {
            candidates = [compact(value)]
        }
        guard candidates.allSatisfy({ $0.count >= 2 }) else { return nil }
        for (pageIndex, lines) in pages.enumerated() {
            for (lineIndex, line) in lines.enumerated() where candidates.contains(where: compact(line).contains) {
                return LineLocation(page: pageIndex, line: lineIndex)
            }
        }
        return nil
    }

    /// Whether an OCR line shows any of the sensitive values read from the same document, such as an I-94
    /// line that prints the name and the passport number together.
    static func line(_ line: String, showsAnyOf facts: [VerifiedFact]) -> Bool {
        let compacted = compact(line)
        return facts
            .filter(\.key.isSensitive)
            .flatMap { [$0.value, $0.alternate].compactMap { $0 } }
            .map(compact)
            .contains { $0.count >= 4 && compacted.contains($0) }
    }

    // MARK: Day and month order

    enum DateOrder: Sendable { case monthFirst, dayFirst }

    /// How the document writes numeric dates such as 08/12/1990: from a date that can only be read one way
    /// (13/05/2020, 05/13/2020), else from where it's from (US cards, notices and leases put the month first).
    static func numericDateOrder(in pages: [[String]], kind: DocumentKind?) -> DateOrder? {
        var monthFirst = 0, dayFirst = 0
        if let regex = try? Regex(#"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})\b"#) {
            for line in pages.joined() {
                for match in line.matches(of: regex) {
                    guard let a = match.output[1].substring.flatMap({ Int($0) }), let b = match.output[2].substring.flatMap({ Int($0) }) else { continue }
                    if a > 12, b <= 12 { dayFirst += 1 }
                    if b > 12, a <= 12 { monthFirst += 1 }
                }
            }
        }
        if monthFirst != dayFirst { return monthFirst > dayFirst ? .monthFirst : .dayFirst }
        switch kind {
        case .greenCard, .employmentAuthorization, .driversLicense, .stateID, .uscisNotice, .i94, .lease: return .monthFirst
        default: return nil
        }
    }

    /// A date the model read with day and month swapped (1990-12-08 for 08/12/1990 on a US card) is put back
    /// the way the page writes it. Only when the page shows the other reading and not this one.
    static func correctedDate(_ date: SimpleDate, pages: [[String]], order: DateOrder?) -> SimpleDate {
        guard let order, date.day <= 12, date.day != date.month,
              let swapped = SimpleDate(year: date.year, month: date.day, day: date.month) else { return date }
        let text = pages.joined().map(compact)
        func shows(_ candidate: SimpleDate) -> Bool {
            let first = order == .monthFirst ? candidate.month : candidate.day
            let second = order == .monthFirst ? candidate.day : candidate.month
            let spellings = Set([
                String(format: "%02d%02d%d", first, second, candidate.year), String(format: "%d%d%d", first, second, candidate.year),
                String(format: "%02d%d%d", first, second, candidate.year), String(format: "%d%02d%d", first, second, candidate.year),
            ])
            return text.contains { line in spellings.contains { line.contains($0) } }
        }
        return !shows(date) && shows(swapped) ? swapped : date
    }

    static func dateSpellings(_ date: SimpleDate) -> [String] {
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let fullMonths = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
        let d = String(format: "%02d", date.day), m = String(format: "%02d", date.month), y = String(date.year)
        let month = months[date.month - 1], full = fullMonths[date.month - 1]
        return [
            "\(y)\(m)\(d)", "\(m)\(d)\(y)", "\(d)\(m)\(y)",
            "\(d)\(month)\(y)", "\(date.day)\(month)\(y)", "\(month)\(d)\(y)", "\(month)\(date.day)\(y)",
            "\(full)\(date.day)\(y)", "\(date.day)\(full)\(y)",
        ]
    }
}
