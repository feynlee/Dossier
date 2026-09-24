import Foundation

/// One line of your compiled personal information.
nonisolated enum ProfileKey: String, CaseIterable, Codable, Sendable {
    case surname
    case givenNames
    case dateOfBirth
    case sex
    case placeOfBirth
    case nationality
    case alienNumber
    case passportNumber
    case licenceNumber
    case currentAddress

    var label: String {
        switch self {
        case .surname: "Surname"
        case .givenNames: "Given names"
        case .dateOfBirth: "Date of birth"
        case .sex: "Sex"
        case .placeOfBirth: "Place of birth"
        case .nationality: "Nationality"
        case .alienNumber: "A-Number"
        case .passportNumber: "Passport number"
        case .licenceNumber: "Driver’s licence number"
        case .currentAddress: "Current address"
        }
    }

    var isSensitive: Bool {
        switch self {
        case .alienNumber, .passportNumber, .licenceNumber: true
        default: false
        }
    }

    var isDate: Bool { self == .dateOfBirth }

    /// The document fact each key is compiled from, for keys reconciled across documents.
    var factKey: FactKey? {
        switch self {
        case .surname: .surname
        case .givenNames: .givenNames
        case .dateOfBirth: .dateOfBirth
        case .sex: .sex
        case .placeOfBirth: .placeOfBirth
        case .nationality: .nationality
        case .alienNumber: .alienNumber
        case .passportNumber, .licenceNumber, .currentAddress: nil
        }
    }

    /// Which documents are trusted for this key, most authoritative first.
    var sources: [DocumentKind] {
        switch self {
        case .surname, .givenNames, .dateOfBirth:
            [.passport, .greenCard, .employmentAuthorization, .visa, .driversLicense, .stateID, .i94, .uscisNotice]
        case .sex: [.passport, .greenCard, .employmentAuthorization, .driversLicense, .stateID]
        case .placeOfBirth: [.passport, .greenCard, .employmentAuthorization]
        case .nationality: [.passport, .visa]
        case .alienNumber: [.greenCard, .employmentAuthorization, .uscisNotice]
        case .passportNumber: [.passport]
        case .licenceNumber: [.driversLicense, .stateID]
        case .currentAddress: []
        }
    }
}

/// One document's reading of a profile value.
nonisolated struct ProfileCandidate: Sendable, Equatable {
    /// Identifies the fact it came from.
    var id: String
    /// What's compared: the normalized value, or for a sensitive value its fingerprint.
    var matchKey: String
    /// The readable value, used to pick the most complete spelling ("ANNA MARIA" over "ANNA M").
    var value: String
    var sourceTitle: String
    /// Position of the source in `ProfileKey.sources`: lower is more authoritative.
    var priority: Int
    /// Confirmed by a checksum (MRZ, barcode) or by you.
    var isChecked: Bool
    /// The model was sure of the reading.
    var isCertain: Bool
}

nonisolated struct ReconciledEntry: Sendable, Equatable {
    enum Status: Equatable, Sendable {
        /// Several documents, all agreeing.
        case agreed(count: Int)
        /// Only one document has it.
        case single
        /// Documents show different values; you choose.
        case conflict
        /// Only readings the model wasn't sure about; they're in Review.
        case uncertain
        case missing
    }

    var key: ProfileKey
    var status: Status
    var chosen: ProfileCandidate?
    /// Each distinct reading, most authoritative first. More than one only for a conflict.
    var groups: [[ProfileCandidate]]
}

/// Compiles profile values across documents. Values that agree are accepted without asking; only
/// disagreements and doubtful readings are left for you.
nonisolated enum Reconciler {
    static func reconcile(_ key: ProfileKey, candidates: [ProfileCandidate]) -> ReconciledEntry {
        let certain = candidates.filter(\.isCertain)
        guard !certain.isEmpty else {
            return ReconciledEntry(key: key, status: candidates.isEmpty ? .missing : .uncertain, chosen: nil, groups: candidates.isEmpty ? [] : [candidates])
        }

        var groups: [[ProfileCandidate]] = []
        for candidate in certain {
            if let index = groups.firstIndex(where: { group in group.contains { equivalent($0.matchKey, candidate.matchKey, key: key) } }) {
                groups[index].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        groups = groups.map { $0.sorted(by: better) }.sorted { better($0[0], $1[0]) }

        let status: ReconciledEntry.Status
        if groups.count > 1 {
            status = .conflict
        } else {
            status = groups[0].count > 1 ? .agreed(count: groups[0].count) : .single
        }
        return ReconciledEntry(key: key, status: status, chosen: groups.count == 1 ? groups[0][0] : nil, groups: groups)
    }

    /// Checked beats unchecked, then the more authoritative document, then the more complete spelling.
    private static func better(_ lhs: ProfileCandidate, _ rhs: ProfileCandidate) -> Bool {
        if lhs.isChecked != rhs.isChecked { return lhs.isChecked }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.value.count > rhs.value.count
    }

    // MARK: Normalization

    /// The form values are compared in. For sensitive keys this is what gets fingerprinted.
    static func normalize(_ value: String, for key: ProfileKey) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).uppercased()
        switch key {
        case .surname, .givenNames:
            let letters = folded.map { $0.isLetter ? $0 : " " }
            return String(letters).split(separator: " ").joined(separator: " ")
        case .dateOfBirth:
            return SimpleDate(iso: value)?.iso ?? folded
        case .sex:
            return String(folded.first { $0.isLetter } ?? " ")
        case .placeOfBirth, .nationality:
            return String(folded.filter(\.isLetter))
        case .alienNumber:
            let digits = folded.filter(\.isNumber).drop { $0 == "0" }
            return String(digits)
        case .passportNumber, .licenceNumber, .currentAddress:
            return String(folded.filter { $0.isLetter || $0.isNumber })
        }
    }

    static func equivalent(_ lhs: String, _ rhs: String, key: ProfileKey) -> Bool {
        if lhs == rhs { return true }
        switch key {
        case .surname, .givenNames:
            return namesCompatible(lhs, rhs)
        case .placeOfBirth, .nationality:
            // "UTOPIA" and "UTOPIAN", "SWEDEN" and "SWEDISH" name the same country.
            return lhs.count >= 4 && rhs.count >= 4 && lhs.prefix(4) == rhs.prefix(4)
        default:
            return false
        }
    }

    /// "ANNA MARIA" matches "ANNA", "ANNA M" and "A MARIA": the shorter name's words must line up with the
    /// longer name's from the first word, each equal or an initial.
    static func namesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.split(separator: " "), b = rhs.split(separator: " ")
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard !short.isEmpty else { return false }
        return zip(short, long).allSatisfy { x, y in
            x == y || (x.count == 1 && y.hasPrefix(x)) || (y.count == 1 && x.hasPrefix(y))
        }
    }
}
