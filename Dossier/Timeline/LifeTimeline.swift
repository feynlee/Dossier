import Foundation

/// Where you lived, what status you held, which documents were valid and when you travelled, as intervals on
/// one time axis. Every Timeline view and the Siri answers read from this; the model never computes dates.
nonisolated struct LifeTimeline: Sendable {
    struct Home: Identifiable, Hashable, Sendable {
        var id: String
        var address: String
        var start: SimpleDate
        /// nil while it's your current home.
        var end: SimpleDate?
        var source: String
        var fromLicence = false
    }

    struct Span: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var start: SimpleDate?
        var end: SimpleDate?
        var source: String
    }

    struct Gap: Hashable, Sendable {
        var start: SimpleDate
        var end: SimpleDate
    }

    struct TravelRow: Hashable, Sendable {
        var id: String
        var date: SimpleDate
        var isArrival: Bool
        var port: String
        var destination: String?
    }

    struct Trip: Identifiable, Hashable, Sendable {
        var id: String { departureID }
        var departureID: String
        var departure: SimpleDate
        var departurePort: String
        /// nil while you're still away.
        var arrival: SimpleDate?
        var arrivalPort: String?
        var destination: String?
        /// The last departure on record with no arrival after it: you may still be away.
        var isOngoing = false

        /// A trip with a missing return record isn't counted; the UI says the return isn't on record.
        var isMissingReturn: Bool { arrival == nil && !isOngoing }

        func days(today: SimpleDate) -> Int {
            if let arrival { return departure.days(to: arrival) }
            return isOngoing ? departure.days(to: today) : 0
        }
    }

    private(set) var homes: [Home]
    private(set) var gaps: [Gap]
    private(set) var statuses: [Span]
    private(set) var documents: [Span]
    private(set) var trips: [Trip]
    let today: SimpleDate

    /// Gaps shorter than this between two homes are moving days, not missing history.
    static let minimumGapDays = 31

    init(homes: [Home], statuses: [Span], documents: [Span], travel: [TravelRow], today: SimpleDate) {
        self.today = today
        self.homes = Self.resolveHomes(homes)
        self.gaps = Self.gaps(between: self.homes)
        self.statuses = statuses.sorted { ($0.start ?? today) < ($1.start ?? today) }
        self.documents = documents.sorted { ($0.start ?? $0.end ?? today) < ($1.start ?? $1.end ?? today) }
        self.trips = Self.pair(travel)
    }

    // MARK: Queries

    var isEmpty: Bool { homes.isEmpty && statuses.isEmpty && documents.isEmpty && trips.isEmpty }

    /// The years any record touches, for the scrubber.
    var years: ClosedRange<Int> {
        let starts = homes.map(\.start) + statuses.compactMap(\.start) + trips.map(\.departure)
        let first = starts.min()?.year ?? today.year
        return min(first, today.year)...today.year
    }

    func home(on date: SimpleDate) -> Home? {
        homes.first { $0.start <= date && date <= ($0.end ?? today) }
    }

    func homes(in year: Int) -> [Home] {
        homes.filter { overlaps(start: $0.start, end: $0.end, year: year) }
    }

    func statuses(on date: SimpleDate) -> [Span] {
        statuses.filter { ($0.start ?? .distantPast) <= date && date <= ($0.end ?? today) }
    }

    func statuses(in year: Int) -> [Span] {
        statuses.filter { overlaps(start: $0.start ?? .distantPast, end: $0.end, year: year) }
    }

    func validDocuments(on date: SimpleDate) -> [Span] {
        documents.filter { ($0.start ?? .distantPast) <= date && date <= ($0.end ?? .distantFuture) }
    }

    func trips(in year: Int) -> [Trip] {
        trips.filter { overlaps(start: $0.departure, end: $0.arrival ?? ($0.isOngoing ? today : $0.departure), year: year) }
    }

    func gaps(in year: Int) -> [Gap] {
        gaps.filter { overlaps(start: $0.start, end: $0.end, year: year) }
    }

    /// Days spent outside the US in a calendar year, counting from departure day up to (not including) the
    /// day you came back. Trips that cross New Year are split between the two years.
    func daysAbroad(in year: Int) -> Int {
        guard let yearStart = SimpleDate(year: year, month: 1, day: 1), let nextYear = SimpleDate(year: year + 1, month: 1, day: 1) else { return 0 }
        return trips.reduce(0) { total, trip in
            guard !trip.isMissingReturn else { return total }
            let start = max(trip.departure, yearStart)
            let end = min(trip.arrival ?? today, nextYear)
            return total + max(0, start.days(to: end))
        }
    }

    private func overlaps(start: SimpleDate, end: SimpleDate?, year: Int) -> Bool {
        start.year <= year && (end ?? today).year >= year
    }

    // MARK: Building

    /// Sorts homes, merges repeats of the same address, closes open-ended homes at the next move, and drops
    /// licence addresses that a lease or your own entry already covers.
    static func resolveHomes(_ input: [Home]) -> [Home] {
        let primary = input.filter { !$0.fromLicence }
        let licence = input.filter { candidate in
            candidate.fromLicence
                && !primary.contains { sameAddress($0.address, candidate.address) }
                && !primary.contains { $0.start <= candidate.start && candidate.start <= ($0.end ?? .distantFuture) }
        }

        var sorted = (primary + licence).sorted { $0.start < $1.start }
        var merged: [Home] = []
        for home in sorted {
            if var last = merged.last, sameAddress(last.address, home.address) {
                if let lastEnd = last.end, let homeEnd = home.end {
                    last.end = max(lastEnd, homeEnd)
                } else {
                    last.end = nil
                }
                merged[merged.count - 1] = last
            } else {
                merged.append(home)
            }
        }
        sorted = merged
        for index in sorted.indices.dropLast() where sorted[index].end == nil {
            sorted[index].end = sorted[index + 1].start.adding(days: -1)
        }
        return sorted
    }

    static func gaps(between homes: [Home]) -> [Gap] {
        zip(homes, homes.dropFirst()).compactMap { previous, next in
            guard let end = previous.end, end.days(to: next.start) > minimumGapDays else { return nil }
            return Gap(start: end.adding(days: 1), end: next.start.adding(days: -1))
        }
    }

    /// Pairs each departure with the arrival that follows it. A departure followed by another departure has
    /// a missing return record; only the very last departure can mean "still away".
    static func pair(_ rows: [TravelRow]) -> [Trip] {
        let sorted = rows.sorted { $0.date < $1.date }
        var trips: [Trip] = []
        for (index, row) in sorted.enumerated() where !row.isArrival {
            let next = sorted.indices.contains(index + 1) ? sorted[index + 1] : nil
            let arrival = next?.isArrival == true ? next : nil
            trips.append(Trip(
                departureID: row.id, departure: row.date, departurePort: row.port,
                arrival: arrival?.date, arrivalPort: arrival?.port, destination: row.destination,
                isOngoing: next == nil
            ))
        }
        return trips
    }

    static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        let key = { (value: String) in
            String(value.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(24))
        }
        return key(lhs) == key(rhs)
    }
}

nonisolated extension SimpleDate {
    static let distantPast = SimpleDate(year: 1900, month: 1, day: 1)!
    static let distantFuture = SimpleDate(year: 2200, month: 1, day: 1)!

    init(_ date: Date) { self.init(utc: date) }

    static var today: SimpleDate {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return SimpleDate(year: parts.year!, month: parts.month!, day: parts.day!)!
    }

    func adding(days: Int) -> SimpleDate {
        SimpleDate(utc: date.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    func days(to other: SimpleDate) -> Int {
        Int((other.date.timeIntervalSince(date) / 86_400).rounded())
    }

    /// "Aug 2020": the month and year, for intervals.
    var monthYear: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[month - 1]) \(year)"
    }
}
