import Foundation

/// Where each document stands: in use, expired on its printed date, or renewed by a newer version of itself.
/// Pure, so it's tested without SwiftData.
///
/// A document is renewed when a later document of the same series exists: the same person's passport from the
/// same country, their driver's licence or state ID, EAD card or green card, or the household's lease for the
/// same home. A renewed document ended when its renewal started, not on the date printed on it.
nonisolated enum DocumentLifecycle {
    enum Status: Equatable, Sendable {
        /// In use.
        case current
        /// In use until this date, when it ends or its renewal starts, whichever is first.
        case renewing(until: SimpleDate)
        /// Past the expiry date printed on it, with nothing newer to replace it.
        case expired(on: SimpleDate?)
        /// Replaced by a newer version. `ended` is when the newer one started, or the printed end date if that
        /// came first or the newer one's start isn't known.
        case renewed(ended: SimpleDate?)

        /// Expired or renewed: kept for your records, listed after the documents you use.
        var isEnded: Bool {
            switch self {
            case .current, .renewing: false
            case .expired, .renewed: true
            }
        }

        var isRenewed: Bool {
            if case .renewed = self { return true }
            return false
        }
    }

    struct Entry: Sendable {
        var id: String
        /// Documents with the same series are versions of one document; nil for documents that aren't renewed.
        var series: String?
        /// When this version started (issued, or valid from) and when it ends as printed.
        var from: SimpleDate?
        var until: SimpleDate?
        /// The expiry date printed on it is past.
        var isExpired: Bool
        /// When it expired, for the subtitle.
        var expiredOn: SimpleDate?
    }

    /// Each document's status, by id.
    static func statuses(_ entries: [Entry], today: SimpleDate) -> [String: Status] {
        var result: [String: Status] = [:]
        for entry in entries {
            result[entry.id] = entry.isExpired ? .expired(on: entry.expiredOn) : .current
        }
        let series = Dictionary(grouping: entries.filter { $0.series != nil }, by: { $0.series! })
        for versions in series.values where versions.count > 1 {
            let ordered = versions.sorted(by: sortsBefore)
            for (index, entry) in ordered.enumerated() {
                guard let next = ordered[(index + 1)...].first(where: { isNewer($0, than: entry) }) else { continue }
                let ended = endDate(of: entry, renewedBy: next)
                if let ended, ended > today {
                    // The renewal hasn't started yet, so this one is still the one you use.
                    if !entry.isExpired { result[entry.id] = .renewing(until: ended) }
                } else {
                    result[entry.id] = .renewed(ended: ended)
                }
            }
        }
        return result
    }

    /// When a renewed document stopped counting: the day its renewal started, unless its printed end came first.
    static func endDate(of entry: Entry, renewedBy next: Entry) -> SimpleDate? {
        // A renewal that "starts" no later than this one did (a green card's resident-since date, say) says
        // nothing about when this one ended.
        guard let start = next.from, entry.from.map({ start > $0 }) ?? true else { return entry.until }
        guard let until = entry.until else { return start }
        return min(start, until)
    }

    /// Whether `other` is a later version than `entry`. Copies with the same dates (a card's back stored as its
    /// own file, a second scan) are the same version.
    static func isNewer(_ other: Entry, than entry: Entry) -> Bool {
        if let a = entry.from, let b = other.from, a != b { return b > a }
        if let a = entry.until, let b = other.until, a != b { return b > a }
        return false
    }

    private static func sortsBefore(_ a: Entry, _ b: Entry) -> Bool {
        if isNewer(b, than: a) { return true }
        if isNewer(a, than: b) { return false }
        return a.id < b.id
    }

    /// The series key for a document: who it belongs to, what kind it is, and what tells two current ones of the
    /// same kind apart (the country of a passport, the street of a lease). Kinds you can hold several of at
    /// once (visas, notices, I-94s, other documents) have none.
    static func series(kind: DocumentKind, person: String, nationality: String?, address: String?) -> String? {
        switch kind {
        case .passport:
            // Someone with two nationalities holds two current passports.
            return [person, kind.rawValue, normalized(nationality) ?? ""].joined(separator: "|")
        case .driversLicense, .stateID, .greenCard, .employmentAuthorization:
            return [person, kind.rawValue].joined(separator: "|")
        case .lease:
            // A new lease for the same home renews it; a lease for a new home doesn't end the old one early.
            guard let street = normalized(address?.split(separator: ",").first.map(String.init)) else { return nil }
            return [person, kind.rawValue, street].joined(separator: "|")
        case .visa, .uscisNotice, .i94, .other, .addedByYou:
            return nil
        }
    }

    private static func normalized(_ text: String?) -> String? {
        let letters = (text ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? nil : letters
    }

    /// Ended documents after the ones in use. In-use documents keep the order they came in; ended ones go
    /// most recently ended first.
    static func ordered<Item>(_ items: [Item], status: (Item) -> Status, ended: (Item) -> SimpleDate?) -> [Item] {
        let current = items.filter { !status($0).isEnded }
        let past = items.enumerated().filter { status($0.element).isEnded }
            .sorted { a, b in
                let x = ended(a.element), y = ended(b.element)
                if x != y { return (x ?? SimpleDate(utc: .distantPast)) > (y ?? SimpleDate(utc: .distantPast)) }
                return a.offset < b.offset
            }
            .map(\.element)
        return current + past
    }
}

extension DocumentLifecycle.Status {
    /// The date the subtitle shows for an ended document.
    var endedOn: SimpleDate? {
        switch self {
        case .current, .renewing: nil
        case .expired(let date), .renewed(let date): date
        }
    }
}

extension Array where Element == SourceDocument {
    /// Each document's status by content hash. Documents not read yet, or not placed in the library, are
    /// current unless expired.
    func lifecycle(today: Date = .now) -> [String: DocumentLifecycle.Status] {
        DocumentLifecycle.statuses(map(\.lifecycleEntry), today: SimpleDate(utc: today))
    }
}

extension SourceDocument {
    var lifecycleEntry: DocumentLifecycle.Entry {
        let printedExpiry = expiryDate.map { SimpleDate(utc: $0) }
        guard isReady else { return DocumentLifecycle.Entry(id: contentHash, series: nil, isExpired: false, expiredOn: nil) }
        let facts = libraryFacts
        // A lease or an EAD card can end on a date that isn't labelled an expiry date.
        let ended = facts.until.map { $0.date < .now } ?? false
        let series = placement.flatMap { placement in
            DocumentLifecycle.series(
                kind: kind, person: placement.person,
                nationality: kind == .passport ? fact(.nationality).flatMap { VaultReader.value(of: $0) } : nil,
                address: facts.address
            )
        }
        return DocumentLifecycle.Entry(
            id: contentHash, series: series, from: facts.from, until: facts.until,
            isExpired: isExpired || ended, expiredOn: printedExpiry ?? facts.until
        )
    }
}
