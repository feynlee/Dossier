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

        for field in fields {
            var value = normalizedValue(field.value, for: field.key)
            if field.key.isDate, let date = SimpleDate(iso: value) { value = correctedDate(date, pages: pages, order: order).iso }
            guard !value.isEmpty, seen.insert(field.key).inserted else { continue }
            let location = locate(value, key: field.key, in: pages)
            let context = location.map { pages[$0.page][$0.line] }

            if let reference = references[field.key] {
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
