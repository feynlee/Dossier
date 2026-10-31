import CoreGraphics
import Foundation

/// Reads the rows of an I-94 travel history straight from OCR: each row is a date, "Arrival" or "Departure",
/// and a port code. The table is regular enough that this is exact where the language model drops rows (the
/// on-device model read 3 of 9 in testing), and every trip count and days-abroad answer depends on all of them.
nonisolated enum TravelHistoryParser {
    static func rows(in pages: [ReadPage]) -> [ReadTravelEvent] {
        var events: [ReadTravelEvent] = []
        for page in pages {
            for row in rows(lines: page.lines, boxes: page.boxes) {
                if let event = event(in: row) { events.append(event) }
            }
        }
        return events
    }

    /// The page's lines joined into table rows by where they sit; without boxes, each line is a row.
    static func rows(lines: [String], boxes: [CGRect]) -> [String] {
        guard boxes.count == lines.count else { return lines }
        var rows: [(midY: CGFloat, height: CGFloat, parts: [(x: CGFloat, text: String)])] = []
        for (line, box) in zip(lines, boxes) {
            if let index = rows.firstIndex(where: { abs($0.midY - box.midY) < max($0.height, box.height) * 0.5 }) {
                rows[index].parts.append((box.minX, line))
            } else {
                rows.append((box.midY, box.height, [(box.minX, line)]))
            }
        }
        return rows.sorted { $0.midY < $1.midY }.map { $0.parts.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }

    static func event(in row: String) -> ReadTravelEvent? {
        let lower = row.lowercased()
        let isArrival = lower.contains("arrival")
        guard isArrival || lower.contains("departure") else { return nil }
        guard let date = Verifier.looseDate(row, order: .monthFirst) ?? SimpleDate(iso: row.trimmingCharacters(in: .whitespaces)) else { return nil }
        let words = row.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let port = words.last(where: { $0.count == 3 && $0.allSatisfy { $0.isUppercase && $0.isLetter } }) else { return nil }
        return ReadTravelEvent(date: date.iso, kind: isArrival ? "arrival" : "departure", port: port)
    }
}
