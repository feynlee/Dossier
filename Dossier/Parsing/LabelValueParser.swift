import CoreGraphics
import Foundation

/// Reads the "label   value" rows of a form-like page straight from OCR: a short label on the left and its value
/// on the same row to the right, under the nearest heading. Seen in testing: on a clean health summary the
/// on-device model returned only a few holder details and never the blood type, primary care physician,
/// allergies or emergency contact, although every one is printed as such a row.
///
/// Only rows the model's reading doesn't already have are added, so the model's richer rows (tables joined
/// with " · ") stay as they are.
nonisolated enum LabelValueParser {
    struct Row: Equatable {
        var section: String
        var label: String
        var value: String
        var page: Int
    }

    private struct Box {
        var text: String
        var rect: CGRect
    }

    static func rows(in pages: [ReadPage]) -> [Row] {
        var out: [Row] = []
        for (index, page) in pages.enumerated() where page.boxes.count == page.lines.count {
            let boxes = zip(page.lines, page.boxes)
                .map { Box(text: $0.trimmingCharacters(in: .whitespaces), rect: $1) }
                .filter { !$0.text.isEmpty }
            var section = "Other"
            for row in rowsOf(boxes) {
                if row.count == 1 {
                    if isHeading(row[0].text) { section = sentenceCase(row[0].text) }
                    continue
                }
                // Exactly a label and a value: a third column makes it a table row, which the model reads better.
                guard row.count == 2 else { continue }
                let (label, value) = (row[0], row[1])
                guard isLabel(label.text), value.rect.minX - label.rect.maxX > 0.02, !value.text.isEmpty,
                      value.text.lowercased() != label.text.lowercased() else { continue }
                out.append(Row(section: section, label: label.text.trimmingCharacters(in: CharacterSet(charactersIn: ":")),
                               value: value.text, page: index + 1))
            }
        }
        return out
    }

    /// The page's boxes grouped into rows (centres within half a line of each other), each sorted left to right.
    private static func rowsOf(_ boxes: [Box]) -> [[Box]] {
        var rows: [[Box]] = []
        for box in boxes.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rows.last?.last, abs(last.rect.midY - box.rect.midY) < min(last.rect.height, box.rect.height) * 0.5 {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// A label: a few words, no digits, not a sentence.
    static func isLabel(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return (1...5).contains(words.count) && text.count <= 40 && !text.contains(where: \.isNumber)
            && !text.hasSuffix(".") && text.first?.isLetter == true
    }

    /// A heading: a short line of words on its own row, such as "Allergies" or "Vitals and blood type".
    static func isHeading(_ text: String) -> Bool {
        isLabel(text) && !text.contains("·") && !text.uppercased().contains("SPECIMEN")
    }

    static func sentenceCase(_ text: String) -> String {
        guard text == text.uppercased() else { return text }
        let lower = text.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// The reading with the rows it missed added as contents.
    static func apply(to reading: DocumentReading, pages: [ReadPage]) -> DocumentReading {
        guard reading.kind == DocumentKind.other.rawValue else { return reading }
        var reading = reading
        func compact(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var known = Set(reading.contents.map { compact($0.label) } + reading.details.map { compact($0.label) })
        // A value the model already filed under another label isn't added again.
        let values = Set(reading.contents.map { compact($0.value) } + reading.details.map { compact($0.value) })
        for row in rows(in: pages) where !known.contains(compact(row.label)) && !values.contains(compact(row.value)) {
            known.insert(compact(row.label))
            let isNumber = row.value.contains(where: \.isNumber) && Verifier.isIdentifier(row.value) ? "yes" : "no"
            reading.contents.append(ReadEntry(section: row.section, label: row.label, value: row.value, page: row.page, confidence: "high", isNumber: isNumber))
        }
        return reading
    }
}
