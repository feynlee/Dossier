import Foundation
import LocalAuthentication

/// What kind of value an entry holds, which decides how it's written into a field.
nonisolated enum FormValueKind: String, Codable, Sendable {
    case text, date, sex, country, number
}

/// One value Dossier can put into a form: your family name, your father's date of birth, the street of
/// your second-to-last address. Values stay sealed: ordinary ones under the vault key, numbers under the
/// Face ID–gated key.
nonisolated struct FormEntry: Identifiable, Hashable, Codable, Sendable {
    /// What the value is, without whose or which: "you.familyName", "family.father.dateOfBirth",
    /// "previousAddress.street". Slots and their labels never contain values, so they can be sent to the
    /// model and remembered per website.
    var slot: String
    /// For repeated sections (previous addresses, trips, children): 0 is the most recent or first.
    var row: Int?
    /// A label without values: "Father’s date of birth".
    var label: String
    /// Where it shows in lists, which may name people: "Father · ERIK ERIKSSON".
    var group: String
    var kind: FormValueKind
    var isSensitive: Bool
    var sealed: Data
    /// `•••• •• 4821` for numbers.
    var masked: String?

    var id: String { row.map { "\(slot)#\($0)" } ?? slot }
}

/// Everything Dossier can fill into a form, compiled from your personal information, the details and
/// family your documents show, your address history and your trips. PDF forms, websites and AutoFill all
/// use it, so they never disagree.
nonisolated struct FormCatalog: Sendable {
    private(set) var entries: [FormEntry]

    init(entries: [FormEntry]) {
        self.entries = entries
    }

    func entry(_ id: String) -> FormEntry? { entries.first { $0.id == id } }

    /// The entries for a slot, first row first.
    func entries(slot: String) -> [FormEntry] {
        entries.filter { $0.slot == slot }.sorted { ($0.row ?? 0) < ($1.row ?? 0) }
    }

    /// Each slot once, with its label, for matching.
    var slots: [(slot: String, label: String)] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.slot).inserted ? ($0.slot, Self.slotLabel($0)) : nil }
    }

    /// Opens a value. Numbers need a context that passed Face ID.
    func value(of entry: FormEntry, context: LAContext?) -> String? {
        if entry.isSensitive {
            guard let context else { return nil }
            return try? Sealer.shared.openSensitive(entry.sealed, context: context)
        }
        return try? Sealer.shared.open(entry.sealed)
    }

    /// The row-free label: "Previous address · street" rather than "Previous address 2 · street".
    private static func slotLabel(_ entry: FormEntry) -> String { entry.label }

    /// Whether any value in `ids` needs Face ID.
    func needsFaceID(_ ids: some Sequence<String>) -> Bool {
        ids.contains { entry($0)?.isSensitive == true }
    }
}

// MARK: Building

extension FormCatalog {
    /// Builds the catalog from the vault. Values are sealed again as they're copied, so the catalog can be
    /// kept (for AutoFill) without anything in the clear.
    @MainActor
    static func build(documents: [SourceDocument], overrides: [ProfileOverride]) -> FormCatalog {
        let ready = documents.filter { !$0.isGone && $0.isReady }
        let timeline = TimelineLoader.timeline(from: ready)
        let profile = Profile.build(documents: ready, overrides: overrides, timeline: timeline)
        let details = ProfileDetails.build(documents: ready)
        var builder = Builder()

        // You.
        let you = "You"
        let surname = profile.value(.surname, context: nil)
        let givenNames = profile.value(.givenNames, context: nil)
        let given = givenNames?.split(separator: " ").map(String.init) ?? []
        builder.add("you.familyName", "Family name", group: you, surname)
        builder.add("you.givenNames", "Given names", group: you, givenNames)
        builder.add("you.givenName", "First name", group: you, given.first)
        builder.add("you.middleName", "Middle name", group: you, given.count > 1 ? given.dropFirst().joined(separator: " ") : nil)
        builder.add("you.fullName", "Full name", group: you, [givenNames, surname].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
        builder.add("you.dateOfBirth", "Date of birth", group: you, profile.value(.dateOfBirth, context: nil), kind: .date)
        let birthplace = profile.value(.placeOfBirth, context: nil)
        builder.add("you.placeOfBirth", "Place of birth", group: you, birthplace)
        builder.add("you.cityOfBirth", "City of birth", group: you, birthplace.map(Self.city))
        builder.add("you.countryOfBirth", "Country of birth", group: you, birthplace.flatMap(Self.country), kind: .country)
        builder.add("you.sex", "Sex", group: you, profile.value(.sex, context: nil), kind: .sex)
        builder.add("you.nationality", "Nationality", group: you, profile.value(.nationality, context: nil), kind: .country)
        builder.addSensitive("you.alienNumber", "A-Number", group: you, profile: profile, key: .alienNumber)
        for detail in details.you {
            builder.addDetail("you.detail.\(Self.slugify(detail.label))", detail.label, group: you, detail: detail)
        }

        // Documents.
        builder.addSensitive("passport.number", "Passport number", group: "Passport", profile: profile, key: .passportNumber)
        if let passport = profile.entry(.passportNumber)?.fact?.document {
            builder.add("passport.issueDate", "Passport issue date", group: "Passport", passport.fact(.issueDate).flatMap { VaultReader.value(of: $0) }, kind: .date)
            builder.add("passport.expiryDate", "Passport expiry date", group: "Passport", passport.fact(.expiryDate).flatMap { VaultReader.value(of: $0) }, kind: .date)
            builder.add("passport.issuingCountry", "Passport issuing country", group: "Passport", passport.fact(.issuingAuthority).flatMap { VaultReader.value(of: $0) }, kind: .country)
        }
        builder.addSensitive("licence.number", "Driver’s licence number", group: "Driver’s licence", profile: profile, key: .licenceNumber)
        if let licence = profile.entry(.licenceNumber)?.fact?.document {
            builder.add("licence.expiryDate", "Driver’s licence expiry date", group: "Driver’s licence", licence.fact(.expiryDate).flatMap { VaultReader.value(of: $0) }, kind: .date)
        }
        if let i94 = ready.first(where: { $0.kind == .i94 }), let fact = i94.fact(.i94Number) {
            builder.addSealed("i94.number", "I-94 number", group: "I-94", fact: fact)
        }

        // Where you live, then where you lived.
        let current = timeline.home(on: timeline.today) ?? timeline.homes.last
        let address = profile.value(.currentAddress, context: nil) ?? current?.address
        if let address {
            builder.addAddress(prefix: "address", label: "", group: "Current address", address: address, row: nil)
            builder.add("address.from", "Lived at the current address since", group: "Current address", current?.start.iso, kind: .date)
        }
        let previous = timeline.homes.filter { $0.id != current?.id }.sorted { $0.start > $1.start }
        for (row, home) in previous.enumerated() {
            let group = "Previous address \(row + 1)"
            builder.addAddress(prefix: "previousAddress", label: "Previous address", group: group, address: home.address, row: row)
            builder.add("previousAddress.from", "Previous address · from", group: group, home.start.iso, kind: .date, row: row)
            builder.add("previousAddress.to", "Previous address · to", group: group, home.end?.iso, kind: .date, row: row)
        }

        // Trips outside the US (from I-94 records), newest first, and arrivals into the US.
        let trips = timeline.trips.sorted { $0.departure > $1.departure }
        for (row, trip) in trips.enumerated() {
            let group = "Trip \(row + 1)"
            builder.add("trip.departure", "Trip · date left the US", group: group, trip.departure.iso, kind: .date, row: row)
            builder.add("trip.return", "Trip · date returned to the US", group: group, trip.arrival?.iso, kind: .date, row: row)
            builder.add("trip.days", "Trip · days outside the US", group: group, trip.arrival == nil ? nil : String(trip.days(today: timeline.today)), kind: .number, row: row)
            builder.add("trip.destination", "Trip · destination", group: group, trip.destination, kind: .country, row: row)
        }
        let arrivals = trips.compactMap { trip in trip.arrival.map { ($0, trip.arrivalPort) } }
        for (row, arrival) in arrivals.enumerated() {
            builder.add("usArrival.date", "Arrival in the US · date", group: "Arrival \(row + 1)", arrival.0.iso, kind: .date, row: row)
            builder.add("usArrival.port", "Arrival in the US · port", group: "Arrival \(row + 1)", arrival.1, row: row)
        }

        // Family. Children and siblings repeat; the others are one person each.
        var counts: [Relation: Int] = [:]
        for person in details.family {
            let row: Int?
            if person.relation == .child || person.relation == .sibling {
                row = counts[person.relation, default: 0]
                counts[person.relation] = (row ?? 0) + 1
            } else {
                // One father, one mother, one spouse: the first found.
                guard counts[person.relation] == nil else { continue }
                counts[person.relation] = 1
                row = nil
            }
            let prefix = "family.\(person.relation.rawValue)"
            let who = person.relation.label
            let group = person.title
            let name = person.details.first { $0.label.lowercased() == "name" }?.value ?? person.name
            let parts = name?.split(separator: " ").map(String.init) ?? []
            builder.add("\(prefix).fullName", "\(who)’s full name", group: group, name, row: row)
            builder.add("\(prefix).familyName", "\(who)’s family name", group: group, parts.count > 1 ? parts.last : nil, row: row)
            builder.add("\(prefix).givenName", "\(who)’s given names", group: group, parts.count > 1 ? parts.dropLast().joined(separator: " ") : nil, row: row)
            for detail in person.details where detail.label.lowercased() != "name" {
                let slug = Self.slugify(detail.label)
                let kind: FormValueKind = detail.value.flatMap(SimpleDate.init(iso:)) != nil ? .date : (slug == "nationality" ? .country : .text)
                builder.addDetail("\(prefix).\(Self.knownSlug(slug))", "\(who)’s \(detail.label.lowercased())", group: group, detail: detail, kind: kind, row: row)
            }
        }
        return FormCatalog(entries: builder.entries)
    }

    /// "STOCKHOLM, SWEDEN" → "STOCKHOLM".
    static func city(_ place: String) -> String {
        place.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? place
    }

    /// "STOCKHOLM, SWEDEN" → "SWEDEN"; nil without a comma.
    static func country(_ place: String) -> String? {
        let parts = place.split(separator: ",")
        return parts.count > 1 ? parts.last?.trimmingCharacters(in: .whitespaces) : nil
    }

    /// "Eye colour" → "eye-color".
    static func slugify(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "colour", with: "color")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }

    /// Family details that forms ask for by name get the same slugs as yours.
    static func knownSlug(_ slug: String) -> String {
        switch slug {
        case "date-of-birth", "birth-date", "born": "dateOfBirth"
        case "place-of-birth", "birthplace", "city-of-birth": "placeOfBirth"
        case "nationality", "citizenship": "nationality"
        default: "detail.\(slug)"
        }
    }

    private struct Builder {
        var entries: [FormEntry] = []

        mutating func add(_ slot: String, _ label: String, group: String, _ value: String?, kind: FormValueKind = .text, row: Int? = nil) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  let sealed = try? Sealer.shared.seal(value, sensitive: false) else { return }
            entries.append(FormEntry(slot: slot, row: row, label: label, group: group, kind: kind, isSensitive: false, sealed: sealed))
        }

        @MainActor
        mutating func addSensitive(_ slot: String, _ label: String, group: String, profile: Profile, key: ProfileKey) {
            guard let entry = profile.entry(key) else { return }
            let sealed = entry.override.flatMap { $0.isSensitive ? $0.sealedValue : nil } ?? entry.fact?.sealedValue
            guard let sealed else { return }
            entries.append(FormEntry(slot: slot, label: label, group: group, kind: .text, isSensitive: true, sealed: sealed, masked: profile.masked(key)))
        }

        @MainActor
        mutating func addSealed(_ slot: String, _ label: String, group: String, fact: Fact) {
            entries.append(FormEntry(slot: slot, label: label, group: group, kind: .text, isSensitive: fact.isSensitive, sealed: fact.sealedValue, masked: fact.isSensitive ? VaultReader.masked(fact) : nil))
        }

        @MainActor
        mutating func addDetail(_ slot: String, _ label: String, group: String, detail: ProfileDetails.Detail, kind: FormValueKind = .text, row: Int? = nil) {
            if detail.isSensitive {
                entries.append(FormEntry(slot: slot, row: row, label: label, group: group, kind: kind, isSensitive: true, sealed: detail.fact.sealedValue, masked: VaultReader.masked(detail.fact)))
            } else {
                add(slot, label, group: group, detail.value, kind: detail.value.flatMap(SimpleDate.init(iso:)) != nil ? .date : kind, row: row)
            }
        }

        mutating func addAddress(prefix: String, label: String, group: String, address: String, row: Int?) {
            let parts = AddressParts(address)
            let lead = label.isEmpty ? "" : "\(label) · "
            add("\(prefix).full", "\(lead)\(label.isEmpty ? "Address" : "full address")", group: group, address, row: row)
            add("\(prefix).street", "\(lead)\(label.isEmpty ? "Street" : "street")", group: group, parts.street, row: row)
            add("\(prefix).unit", "\(lead)\(label.isEmpty ? "Apt, suite or unit" : "apt, suite or unit")", group: group, parts.unit, row: row)
            add("\(prefix).city", "\(lead)\(label.isEmpty ? "City" : "city")", group: group, parts.city, row: row)
            add("\(prefix).state", "\(lead)\(label.isEmpty ? "State" : "state")", group: group, parts.state, row: row)
            add("\(prefix).postalCode", "\(lead)\(label.isEmpty ? "ZIP code" : "ZIP code")", group: group, parts.postalCode, row: row)
            if parts.postalCode != nil {
                add("\(prefix).country", "\(lead)\(label.isEmpty ? "Country" : "country")", group: group, "United States", kind: .country, row: row)
            }
        }
    }
}
