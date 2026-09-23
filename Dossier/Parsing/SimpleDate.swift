import Foundation

/// A calendar date with no time zone: what documents print. Stored and compared as year/month/day so a
/// birth date never shifts by a day when the phone changes time zone.
nonisolated struct SimpleDate: Hashable, Comparable, Codable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day), (1800...2200).contains(year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`, the format the extraction schema asks the model for.
    init?(iso: String) {
        let parts = iso.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Parses an MRZ `YYMMDD` date. Birth dates are placed in the past; expiry dates in 2000–2099.
    init?(mrz: some StringProtocol, isBirthDate: Bool, now: Date = .now) {
        guard mrz.count == 6, let yy = Int(mrz.prefix(2)), let mm = Int(mrz.dropFirst(2).prefix(2)), let dd = Int(mrz.suffix(2)) else {
            return nil
        }
        let currentYY = Calendar(identifier: .gregorian).component(.year, from: now) % 100
        let century = isBirthDate ? (yy > currentYY ? 1900 : 2000) : 2000
        self.init(year: century + yy, month: mm, day: dd)
    }

    /// The inverse of `date`: reads the calendar date of a midnight-UTC `Date`.
    init(utc date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// `14 Mar 2029`: the unambiguous format the design system uses everywhere in the UI.
    var display: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day) \(months[month - 1]) \(year)"
    }

    /// Midnight UTC on this date, for sorting and for "expires in N months" arithmetic.
    var date: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    static func < (lhs: SimpleDate, rhs: SimpleDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
