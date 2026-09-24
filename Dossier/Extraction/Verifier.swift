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

    static func verify(_ fields: [Input], pages: [[String]], mrz: MRZResult?, license: AAMVARecord?) -> [VerifiedFact] {
        let references = references(mrz: mrz, license: license)
        var results: [VerifiedFact] = []
        var seen = Set<FactKey>()

        for field in fields {
            let value = normalizedValue(field.value, for: field.key)
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
