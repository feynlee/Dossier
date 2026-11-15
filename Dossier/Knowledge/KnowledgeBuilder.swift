import Foundation

/// Turns document snapshots into topics, settling disagreements between documents. The rules, in short:
/// - Facts that never change (birth date, legal name) go with the strongest, most authoritative, most common
///   reading; a lone weaker outlier is flagged as a probable typo, two strong readings that differ are a conflict.
/// - Facts that change (address, phone, status) go with the newest evidence; older values become history.
/// - Facts of a document you may have several of (passports, licences, leases) come from the one in force today.
/// - Events (vaccine doses, trips) all count; "the last one" is the latest.
/// - An addendum or a later lease that ends a lease early shortens that lease.
nonisolated enum KnowledgeBuilder {
    static let household = "Household"

    static func build(_ documents: [KnowledgeDocument], today: SimpleDate) -> Knowledge {
        let documents = documents.map(cleaned)
        // Documents not yet placed in the library have no person: they're yours ("You") until they are.
        let owner = ownerName(documents) ?? (documents.isEmpty ? nil : "You")
        var builder = Builder(documents: documents, owner: owner, today: today)
        builder.run()
        // A notice is about the form its case is for: "my I-485 receipt number" is on the I-797 for the I-485.
        let forms = Dictionary(documents.compactMap { document in document.fields[.formType]?.text.map { (document.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let topics = builder.topics.map { withSourceTerms($0, forms: forms) }
        return Knowledge(today: today, owner: owner, people: builder.people, topics: topics, trips: builder.trips)
    }

    /// Readings with nothing in them say nothing: a field or entry with an empty value (seen in testing: a
    /// "Phone" entry with no number) would otherwise become an answer like "your phone is ,".
    static func cleaned(_ document: KnowledgeDocument) -> KnowledgeDocument {
        var document = document
        func hasValue(_ value: KnowledgeValue) -> Bool {
            if let text = value.text { return !text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty }
            return value.hint != nil || value.fingerprint != nil
        }
        document.fields = document.fields.filter { hasValue($0.value) }
        document.entries = document.entries.filter { hasValue($0.value) && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        return document
    }

    /// A topic is also found by the documents behind each of its values ("rent at Pine Ave" finds the rent of
    /// the lease titled "Lease for 88 Pine Ave", even when today's lease is another one).
    static func withSourceTerms(_ topic: KnowledgeTopic, forms: [String: String] = [:]) -> KnowledgeTopic {
        var topic = topic
        let claims = [topic.current].compactMap { $0 } + topic.others
        let words = claims.flatMap { KnowledgeText.words($0.source.title + " " + (forms[$0.source.documentID] ?? "")) }
            .filter { $0.count > 2 && !$0.allSatisfy(\.isNumber) }
        topic.terms = Array(Set(topic.terms + words))
        return topic
    }

    /// Whose vault it is: the person with the most documents.
    static func ownerName(_ documents: [KnowledgeDocument]) -> String? {
        let names = documents.compactMap(\.person).filter { $0 != household }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: Document dates

    /// When a document starts and stops applying, and the date it speaks for.
    nonisolated struct Window {
        var start: SimpleDate?
        var end: SimpleDate?
        var asOf: SimpleDate?

        func inForce(on day: SimpleDate) -> Bool {
            (start.map { $0 <= day } ?? true) && (end.map { day <= $0 } ?? true)
        }

        /// For ordering documents of a kind: the newest start, else the newest date.
        var recency: SimpleDate? { start ?? asOf ?? end }
    }

    static let identityKeys: [FactKey] = [.surname, .givenNames, .dateOfBirth, .placeOfBirth, .sex, .nationality, .alienNumber]

    /// Labels that date a whole document when it has no issue date of its own.
    static let documentDateLabels = ["signed", "collected", "exam date", "date filed", "date of this", "effective", "printed", "tax year", "date of marriage"]

    // MARK: -

    private nonisolated struct Builder {
        let documents: [KnowledgeDocument]
        let owner: String?
        let today: SimpleDate
        var people: [KnowledgePerson] = []
        var topics: [KnowledgeTopic] = []
        var trips: [KnowledgeTrip] = []
        var windows: [String: Window] = [:]
        var notes: [String: String] = [:]

        init(documents: [KnowledgeDocument], owner: String?, today: SimpleDate) {
            self.documents = documents
            self.owner = owner
            self.today = today
        }

        func person(of document: KnowledgeDocument) -> String {
            guard let person = document.person, person != KnowledgeBuilder.household else { return owner ?? "You" }
            return person
        }

        mutating func run() {
            for document in documents { windows[document.id] = baseWindow(document) }
            applyAmendments()
            buildPeople()
            fillCrossReferences()
            let byPerson = Dictionary(grouping: documents) { person(of: $0) }
            for (name, owned) in byPerson.sorted(by: { $0.key < $1.key }) {
                credentialTopics(name, owned)
                identityTopics(name, documents.filter { person(of: $0) == name })
                detailTopics(name, owned)
                addressTopic(name, owned)
                statusTopic(name, owned)
                vaccineTopics(name, owned)
                travelTopics(name, owned)
            }
            topics.sort { ($0.person, $0.name) < ($1.person, $1.name) }
        }

        // MARK: Windows

        func baseWindow(_ document: KnowledgeDocument) -> Window {
            let d = { (key: FactKey) in document.date(key) }
            let start = d(.leaseStartDate) ?? d(.validFrom) ?? d(.issueDate) ?? d(.residentSince) ?? d(.noticeDate)
            let end = d(.leaseEndDate) ?? d(.validUntil) ?? d(.expiryDate) ?? d(.admitUntil)
            var asOf = d(.issueDate) ?? d(.noticeDate) ?? d(.validFrom) ?? d(.leaseStartDate) ?? d(.residentSince)
            if asOf == nil {
                asOf = document.entries.first { entry in
                    KnowledgeBuilder.documentDateLabels.contains { entry.label.lowercased().contains($0) }
                }.flatMap { $0.value.text.flatMap(KnowledgeText.date) }
            }
            if asOf == nil, let year = document.entries.first(where: { $0.label.lowercased().contains("tax year") })?.value.text.flatMap({ Int($0.prefix(4)) }) {
                asOf = SimpleDate(year: year + 1, month: 1, day: 31)
            }
            return Window(start: start, end: end, asOf: asOf)
        }

        /// An addendum that ends a lease early, or a later lease elsewhere, shortens the lease.
        mutating func applyAmendments() {
            let leases = documents.filter { $0.kind == .lease }
            for lease in leases {
                guard var window = windows[lease.id], let street = lease.fields[.address]?.text.map(KnowledgeText.street) else { continue }
                // An addendum for the same address that names an earlier end date.
                for other in documents where other.id != lease.id && other.kind != .lease {
                    guard other.fields[.address]?.text.map(KnowledgeText.street) == street else { continue }
                    for entry in other.entries {
                        let words = (entry.label + " " + (entry.section ?? "")).lowercased()
                        guard words.contains("terminat") || words.contains("ends early") || words.contains("ends on") || words.contains("end early") || words.contains("early"),
                              let date = entry.value.text.flatMap(KnowledgeText.date),
                              window.start.map({ $0 < date }) ?? true, window.end.map({ date < $0 }) ?? true
                        else { continue }
                        window.end = date
                        notes[lease.id] = "\(other.title) ended this lease early, on \(date.display)."
                    }
                }
                // A later lease for the same person at another address, starting before this one ends.
                if notes[lease.id] == nil {
                    let next = leases
                        .filter { person(of: $0) == person(of: lease) && $0.id != lease.id }
                        .filter { $0.fields[.address]?.text.map(KnowledgeText.street) != street }
                        .compactMap { other -> SimpleDate? in windows[other.id]?.start }
                        .filter { start in (window.start.map { $0 < start } ?? true) && (window.end.map { start <= $0 } ?? false) }
                        .min()
                    if let next {
                        window.end = SimpleDate(utc: next.date.addingTimeInterval(-86_400))
                        notes[lease.id] = "A later lease starts \(next.display), so this one probably ended then."
                    }
                }
                windows[lease.id] = window
            }
        }

        // MARK: People

        mutating func buildPeople() {
            var names = Set(documents.map { person(of: $0) })
            if let owner { names.insert(owner) }
            var relations: [String: Relation] = [:]
            func match(_ fullName: String?) -> String? {
                guard let first = fullName?.split(separator: " ").first.map({ String($0).lowercased() }) else { return nil }
                return names.first { $0.lowercased() == first }
            }
            for document in documents {
                let holder = person(of: document)
                for entry in document.entries {
                    guard let relation = entry.relation, let other = match(entry.personName), other != holder else { continue }
                    if holder == owner {
                        relations[other] = relation
                    } else if other == owner, relations[holder] == nil {
                        // The other person's document names the owner: invert the relationship.
                        switch relation {
                        case .mother, .father: relations[holder] = .child
                        case .child: relations[holder] = .other
                        case .spouse: relations[holder] = .spouse
                        case .sibling: relations[holder] = .sibling
                        case .other: relations[holder] = .other
                        }
                    }
                }
            }
            people = names.sorted().map { name in
                let theirs = documents.filter { person(of: $0) == name && $0.kind != .lease }
                let given = theirs.compactMap { $0.fields[.givenNames]?.text }.max { $0.count < $1.count }
                let surname = theirs.first { [.passport, .greenCard, .employmentAuthorization, .driversLicense].contains($0.kind) }?.fields[.surname]?.text
                    ?? theirs.compactMap { $0.fields[.surname]?.text }.first
                let full = [given, surname].compactMap { $0 }.joined(separator: " ")
                return KnowledgePerson(name: name, fullName: full.isEmpty ? nil : full.capitalized, relation: name == owner ? nil : (relations[name] ?? .other))
            }
        }

        // MARK: Documents of a kind

        func group(of document: KnowledgeDocument) -> (id: String, name: String) {
            switch document.kind {
            case .driversLicense, .stateID: return ("licence", "Driver’s licence")
            case .uscisNotice:
                let form = document.fields[.formType]?.text ?? "notice"
                return ("uscisNotice|\(KnowledgeText.compact(form))", "\(form) notice")
            case .other, .addedByYou:
                let base = document.fields[.formType]?.text ?? Self.stripYears(document.title)
                return ("other|\(KnowledgeText.compact(base))", Self.stripYears(document.title))
            default: return (document.kind.rawValue, document.kind.displayName)
            }
        }

        static func stripYears(_ title: String) -> String {
            let words = title.split(separator: " ").filter { word in !(word.count == 4 && Int(word).map { (1900...2100).contains($0) } == true) }
            let joined = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ·-,"))
            return joined.isEmpty ? title : joined
        }

        /// Documents of a kind, the one in force today first, then newest first.
        func ranked(_ documents: [KnowledgeDocument]) -> [KnowledgeDocument] {
            documents.sorted { a, b in
                let wa = windows[a.id] ?? Window(), wb = windows[b.id] ?? Window()
                let fa = wa.inForce(on: today), fb = wb.inForce(on: today)
                if fa != fb { return fa }
                return (wa.recency ?? SimpleDate(year: 1800, month: 1, day: 1)!) > (wb.recency ?? SimpleDate(year: 1800, month: 1, day: 1)!)
            }
        }

        func claim(_ value: KnowledgeValue, field: String, in document: KnowledgeDocument, date: SimpleDate? = nil, label: String? = nil) -> KnowledgeClaim {
            let window = windows[document.id]
            // A lease's values carry its address, so "the rent at Pine Ave" finds that lease's rent.
            let label = document.kind == .lease ? document.fields[.address]?.text ?? label : label
            return KnowledgeClaim(
                value: value, field: field, source: KnowledgeSource(documentID: document.id, title: document.title, kind: document.kind),
                date: date ?? window?.asOf ?? window?.start, validFrom: window?.start, validUntil: window?.end, label: label
            )
        }

        mutating func credentialTopics(_ person: String, _ owned: [KnowledgeDocument]) {
            let groups = Dictionary(grouping: owned) { group(of: $0).id }
            for (groupID, members) in groups {
                let ordered = ranked(members)
                let groupName = group(of: ordered[0]).name
                let current = ordered[0]
                let currentWindow = windows[current.id] ?? Window()
                var groupNote: String?
                if members.count > 1 {
                    let state = currentWindow.inForce(on: today) ? "in force today" : "the newest"
                    groupNote = "Answers come from \(current.title)\(currentWindow.start.map { " (\($0.display))" } ?? ""), \(state); \(members.count - 1) other on file."
                }
                // Standard facts, except the ones about the person (those are settled across all documents).
                let keys = Set(members.flatMap(\.fields.keys)).subtracting(KnowledgeBuilder.identityKeys.filter { $0 != .alienNumber })
                for key in keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    var claims = ordered.compactMap { document in document.fields[key].map { claim($0, field: key.rawValue, in: document) } }
                    if key == .leaseEndDate {
                        // Every lease's end as amended, not only today's lease.
                        claims = claims.map { claim in
                            guard let end = claim.validUntil, KnowledgeText.date(claim.value.text ?? "") != end else { return claim }
                            var amended = claim
                            amended.value = .plain(end.iso, strength: claim.value.strength)
                            return amended
                        }
                    }
                    guard let first = claims.first else { continue }
                    var note = groupNote
                    if key == .leaseEndDate, let holder = ordered.first(where: { $0.fields[key] != nil }), let amended = notes[holder.id] { note = amended }
                    var value = first
                    if key == .leaseEndDate, let window = windows[value.source.documentID], let end = window.end,
                       KnowledgeText.date(value.value.text ?? "") != end {
                        value.value = .plain(end.iso, strength: value.value.strength)
                    }
                    topics.append(KnowledgeTopic(
                        id: "\(person)|\(groupID)|\(key.rawValue)", person: person, name: "\(groupName) · \(key.label)", behavior: .credential,
                        current: value, others: Array(claims.dropFirst()), note: note,
                        terms: KnowledgeTerms.terms(person: person, group: groupName, label: key.label, key: key, value: first.value)
                    ))
                }
                // Everything else the documents record, except vaccine doses (those are events).
                var entryClaims: [String: (label: String, section: String?, claims: [KnowledgeClaim])] = [:]
                for document in ordered {
                    var combined: [String: KnowledgeClaim] = [:]
                    // Details about people (section nil) are settled across documents in `detailTopics`.
                    for entry in document.entries where entry.section != nil && entry.relation == nil && !KnowledgeVaccines.isDose(entry) {
                        let label = Self.baseLabel(entry.label)
                        let id = "\(entry.section?.lowercased() ?? "detail")|\(label.lowercased())"
                        if var existing = combined[id], let text = existing.value.text, let more = entry.value.text, !existing.value.isSensitive {
                            existing.value.text = text + ", " + more
                            combined[id] = existing
                        } else if combined[id] == nil {
                            combined[id] = claim(entry.value, field: label, in: document, label: entry.section)
                        }
                        if entryClaims[id] == nil { entryClaims[id] = (label, entry.section, []) }
                    }
                    for (id, claim) in combined { entryClaims[id]?.claims.append(claim) }
                }
                for (id, item) in entryClaims {
                    guard let first = item.claims.first else { continue }
                    let isDetail = item.section == nil
                    topics.append(KnowledgeTopic(
                        id: "\(person)|\(groupID)|\(id)", person: person, name: "\(groupName) · \(item.label)",
                        behavior: isDetail ? .state : .credential, current: first, others: Array(item.claims.dropFirst()), note: groupNote,
                        terms: KnowledgeTerms.terms(person: person, group: groupName, label: [item.section, item.label].compactMap { $0 }.joined(separator: " "), key: nil, value: first.value)
                    ))
                }
            }
        }

        /// "Tenant (2)" → "Tenant": numbered repeats of a label are one topic.
        static func baseLabel(_ label: String) -> String {
            guard label.hasSuffix(")"), let open = label.lastIndex(of: "("), Int(label[label.index(after: open)..<label.index(before: label.endIndex)]) != nil else { return label }
            return String(label[..<open]).trimmingCharacters(in: .whitespaces)
        }

        // MARK: Identity

        mutating func identityTopics(_ person: String, _ owned: [KnowledgeDocument]) {
            var results: [FactKey: KnowledgeClaim] = [:]
            for key in KnowledgeBuilder.identityKeys {
                guard let profileKey = ProfileKey.allCases.first(where: { $0.factKey == key }) else { continue }
                var candidates: [(claim: KnowledgeClaim, match: String, priority: Int)] = []
                for document in owned {
                    guard let value = document.fields[key] else { continue }
                    let match: String
                    if let text = value.text { match = Reconciler.normalize(text, for: profileKey) }
                    else if let fingerprint = value.fingerprint { match = fingerprint }
                    else { continue }
                    let priority = profileKey.sources.firstIndex(of: document.kind) ?? profileKey.sources.count + 1
                    candidates.append((claim(value, field: key.rawValue, in: document), match, priority))
                }
                // Family members named on other documents add their own readings (a marriage certificate's
                // birth date for the spouse).
                candidates += crossReferenced[person]?[key] ?? []
                guard !candidates.isEmpty else { continue }
                // Cards print only the country of birth; that can't contradict a city on a passport.
                var countryOnly: [KnowledgeClaim] = []
                if key == .placeOfBirth, candidates.contains(where: { ![.greenCard, .employmentAuthorization].contains($0.claim.source.kind) }) {
                    countryOnly = candidates.filter { [.greenCard, .employmentAuthorization].contains($0.claim.source.kind) }.map { $0.claim }
                    candidates.removeAll { [.greenCard, .employmentAuthorization].contains($0.claim.source.kind) }
                }

                var groups: [[(claim: KnowledgeClaim, match: String, priority: Int)]] = []
                // Longest first, so "Lumen City, Utopia" can join "Lumen City" and "Utopia" in one group.
                for candidate in candidates.sorted(by: { $0.match.count > $1.match.count }) {
                    if let index = groups.firstIndex(where: { $0.contains { Reconciler.equivalent($0.match, candidate.match, key: profileKey) || Self.sameName(key, $0.match, candidate.match) || Self.samePlace(key, $0.match, candidate.match) } }) {
                        groups[index].append(candidate)
                    } else {
                        groups.append([candidate])
                    }
                }
                func best(_ group: [(claim: KnowledgeClaim, match: String, priority: Int)]) -> (claim: KnowledgeClaim, match: String, priority: Int) {
                    group.max { a, b in
                        if a.claim.value.strength != b.claim.value.strength { return a.claim.value.strength < b.claim.value.strength }
                        if a.priority != b.priority { return a.priority > b.priority }
                        return (a.claim.value.text?.count ?? 0) < (b.claim.value.text?.count ?? 0)
                    }!
                }
                func score(_ group: [(claim: KnowledgeClaim, match: String, priority: Int)]) -> (Int, Int, Int) {
                    let top = best(group)
                    return (top.claim.value.strength.rawValue >= KnowledgeStrength.checksum.rawValue ? 1 : 0, group.count, -top.priority)
                }
                groups.sort { score($0) > score($1) }
                let winner = best(groups[0])
                let others = groups.flatMap { $0 }.map { $0.claim }.filter { $0.id != winner.claim.id } + countryOnly
                var note: String?
                var isConflict = false
                if groups.count > 1 {
                    let outliers = groups.dropFirst().flatMap { $0 }
                    let strongOutlier = outliers.contains { $0.claim.value.strength >= .checksum || ($0.priority < winner.priority && groups[0].count == 1) }
                    if strongOutlier || groups[1].count >= groups[0].count {
                        isConflict = true
                        note = "Documents disagree: \(outliers.map { "\($0.claim.source.title) says \($0.claim.value.spoken)" }.joined(separator: "; "))."
                    } else {
                        note = "\(groups[0].count) documents agree. "
                            + outliers.map { "\($0.claim.source.title) says \($0.claim.value.spoken), probably a mistake." }.joined(separator: " ")
                    }
                } else if groups[0].count > 1 {
                    note = "\(groups[0].count) documents agree."
                }
                results[key] = winner.claim
                topics.append(KnowledgeTopic(
                    id: "\(person)|identity|\(key.rawValue)", person: person, name: key == .alienNumber ? "A-Number" : key.label,
                    behavior: .identity, current: winner.claim, others: others, isConflict: isConflict, note: note,
                    terms: KnowledgeTerms.terms(person: person, group: "", label: key.label, key: key, value: winner.claim.value)
                ))
            }
            // The full name, and other names used (a married name on an insurance card).
            if let given = results[.givenNames], let surname = results[.surname], let g = given.value.text, let s = surname.value.text {
                var full = given
                full.value = .plain("\(g) \(s)", strength: min(given.value.strength, surname.value.strength))
                full.field = "fullName"
                let variants = owned.compactMap { document -> KnowledgeClaim? in
                    guard let other = document.fields[.surname]?.text, KnowledgeText.compact(other) != KnowledgeText.compact(s) else { return nil }
                    let first = document.fields[.givenNames]?.text ?? g
                    return claim(.plain("\(first) \(other)"), field: "otherName", in: document)
                }
                topics.append(KnowledgeTopic(
                    id: "\(person)|identity|fullName", person: person, name: "Full name", behavior: .identity, current: full, others: [],
                    terms: KnowledgeTerms.terms(person: person, group: "", label: "Full legal name", key: nil, value: full.value)
                ))
                if let first = variants.first {
                    topics.append(KnowledgeTopic(
                        id: "\(person)|identity|otherNames", person: person, name: "Other names used", behavior: .identity,
                        current: first, others: Array(variants.dropFirst()),
                        note: "Your identity documents say \(g) \(s); these documents use another name.",
                        terms: KnowledgeTerms.terms(person: person, group: "", label: "Other names used alias maiden married", key: nil, value: first.value)
                    ))
                }
            }
        }

        /// "LUMENCITYUTOPIA" contains "UTOPIA": a fuller spelling of the same place of birth.
        static func samePlace(_ key: FactKey, _ a: String, _ b: String) -> Bool {
            key == .placeOfBirth && min(a.count, b.count) >= 4 && (a.contains(b) || b.contains(a))
        }

        /// "ERIKSSON" and "ERIKSSON CHEN" are the same family name with a married name added.
        static func sameName(_ key: FactKey, _ a: String, _ b: String) -> Bool {
            guard key == .surname else { return false }
            let wa = Set(a.split(separator: " ")), wb = Set(b.split(separator: " "))
            return !wa.isEmpty && !wb.isEmpty && (wa.isSubset(of: wb) || wb.isSubset(of: wa))
        }

        /// Facts about a person found on someone else's documents, filled in by `familyCrossReferences` first.
        var crossReferenced: [String: [FactKey: [(claim: KnowledgeClaim, match: String, priority: Int)]]] = [:]

        /// Birth dates and places printed on other people's documents (a marriage certificate, a child's birth
        /// certificate) and the holder's own on documents that aren't identity documents. They count as weak
        /// readings: they confirm the identity documents, or are the only reading for someone without any.
        mutating func fillCrossReferences() {
            let keys: [String: FactKey] = ["dateofbirth": .dateOfBirth, "placeofbirth": .placeOfBirth, "birthplace": .placeOfBirth,
                                           "sex": .sex, "nationality": .nationality]
            for document in documents {
                let holder = person(of: document)
                for entry in document.entries where entry.section == nil {
                    guard let key = keys[KnowledgeText.compact(entry.label).lowercased()], let text = entry.value.text,
                          let profileKey = ProfileKey.allCases.first(where: { $0.factKey == key }) else { continue }
                    let found: String?
                    if entry.relation == nil {
                        found = holder
                    } else {
                        let first = entry.personName?.split(separator: " ").first.map { String($0).lowercased() }
                        found = people.first { $0.name.lowercased() == first }?.name
                    }
                    guard let subject = found else { continue }
                    var item = claim(.plain(text, strength: min(entry.value.strength, .model)), field: key.rawValue, in: document)
                    item.label = entry.relation.map { "\($0.label) on \(document.title)" }
                    crossReferenced[subject, default: [:]][key, default: []].append((item, Reconciler.normalize(text, for: profileKey), profileKey.sources.count + 2))
                }
            }
        }

        // MARK: Details about people

        mutating func detailTopics(_ person: String, _ owned: [KnowledgeDocument]) {
            var groups: [String: (name: String, relation: Relation?, claims: [KnowledgeClaim])] = [:]
            for document in owned {
                for entry in document.entries where entry.section == nil {
                    let label = entry.label
                    let compactLabel = KnowledgeText.compact(label).lowercased()
                    if entry.relation == nil, ["name", "fullname", "dateofbirth", "placeofbirth", "birthplace", "sex", "nationality"].contains(compactLabel) { continue }
                    let who = entry.personName.map { KnowledgeText.compact($0.split(separator: " ").first.map(String.init) ?? $0) } ?? ""
                    let id = "\(entry.relation?.rawValue ?? "holder")|\(who)|\(compactLabel)"
                    let name = entry.relation.map { "\($0.label) · \(label)" } ?? label
                    if groups[id] == nil { groups[id] = (name, entry.relation, []) }
                    var value = entry.value
                    if entry.relation != nil, label.lowercased() == "name", let personName = entry.personName, value.text == nil || value.text!.isEmpty {
                        value = .plain(personName)
                    }
                    groups[id]?.claims.append(claim(value, field: label, in: document))
                }
            }
            for (id, group) in groups {
                let sorted = group.claims.sorted { ($0.date ?? SimpleDate(year: 1800, month: 1, day: 1)!) > ($1.date ?? SimpleDate(year: 1800, month: 1, day: 1)!) }
                let distinct = Set(sorted.compactMap { $0.value.comparable.map(KnowledgeText.compact) })
                let note = distinct.count > 1 ? "Changed over time; the newest document wins (\(sorted[0].source.title))." : nil
                topics.append(KnowledgeTopic(
                    id: "\(person)|detail|\(id)", person: person, name: group.name, behavior: .state, current: sorted[0], others: Array(sorted.dropFirst()),
                    note: note,
                    terms: KnowledgeTerms.terms(person: person, group: group.relation?.label ?? "", label: group.name, key: nil, value: sorted[0].value)
                        + (group.relation.map(KnowledgeTerms.relationWords) ?? [])
                ))
            }
        }

        // MARK: Address

        mutating func addressTopic(_ person: String, _ owned: [KnowledgeDocument]) {
            var claims: [(claim: KnowledgeClaim, evidence: SimpleDate?, isLease: Bool)] = []
            for document in owned {
                guard let value = document.fields[.address] else { continue }
                let window = windows[document.id] ?? Window()
                var item = claim(value, field: "address", in: document)
                if document.kind == .lease || (document.kind == .addedByYou && window.end != nil) {
                    item.date = window.start
                    claims.append((item, window.start, true))
                } else if document.kind == .driversLicense || document.kind == .stateID || window.asOf != nil {
                    item.validFrom = window.asOf
                    item.validUntil = nil
                    claims.append((item, window.asOf, false))
                }
            }
            guard !claims.isEmpty else { return }
            let floor = SimpleDate(year: 1800, month: 1, day: 1)!
            // Ended leases are history; of what's left, the newest evidence wins.
            let live = claims.filter { !$0.isLease || (windows[$0.claim.source.documentID]?.inForce(on: today) ?? false) }
            let pool = live.isEmpty ? claims : live
            let winner = pool.max { ($0.evidence ?? floor, $0.isLease ? 1 : 0) < ($1.evidence ?? floor, $1.isLease ? 1 : 0) }!
            let winnerStreet = winner.claim.value.text.map(KnowledgeText.street)
            let stale = claims
                .filter { $0.claim.value.text.map(KnowledgeText.street) != winnerStreet && !$0.isLease && ($0.evidence ?? floor) >= (claims.filter { $0.isLease }.compactMap { $0.evidence }.min() ?? floor) }
                // A licence that still shows an old address is the one worth mentioning.
                .sorted { a, b in
                    let la = [.driversLicense, .stateID].contains(a.claim.source.kind), lb = [.driversLicense, .stateID].contains(b.claim.source.kind)
                    return la != lb ? la : (a.evidence ?? floor) > (b.evidence ?? floor)
                }
            var note: String?
            if let old = stale.first {
                note = "\(old.claim.source.title) still shows \(old.claim.value.spoken); \(winner.claim.source.title) is newer."
            }
            if let ended = notes.first(where: { id, _ in claims.contains { $0.claim.source.documentID == id } }) {
                note = [note, ended.value].compactMap { $0 }.joined(separator: " ")
            }
            let others = claims.filter { $0.claim.id != winner.claim.id }.sorted { ($0.evidence ?? floor) > ($1.evidence ?? floor) }.map { $0.claim }
            topics.append(KnowledgeTopic(
                id: "\(person)|state|address", person: person, name: "Address", behavior: .state, current: winner.claim, others: others, note: note,
                terms: KnowledgeTerms.terms(person: person, group: "Home", label: "Address", key: .address, value: winner.claim.value)
            ))
        }

        // MARK: Immigration status

        mutating func statusTopic(_ person: String, _ owned: [KnowledgeDocument]) {
            var claims: [KnowledgeClaim] = []
            for document in owned {
                let window = windows[document.id] ?? Window()
                switch document.kind {
                case .greenCard:
                    guard let category = document.fields[.uscisCategory]?.text else { continue }
                    var item = claim(.plain("Permanent resident (\(category))"), field: "status", in: document, date: document.date(.residentSince))
                    item.validFrom = document.date(.residentSince) ?? window.start
                    item.validUntil = nil
                    claims.append(item)
                case .employmentAuthorization:
                    guard let category = document.fields[.uscisCategory]?.text else { continue }
                    claims.append(claim(.plain("Work permit (EAD \(category))"), field: "status", in: document, date: window.start))
                case .i94:
                    guard let admission = document.fields[.classOfAdmission]?.text else { continue }
                    let entered = document.entries.first { $0.label.lowercased().contains("entry") }?.value.text.flatMap(KnowledgeText.date)
                    var item = claim(.plain("\(admission) (I-94)"), field: "status", in: document, date: entered ?? window.asOf)
                    item.validFrom = entered
                    claims.append(item)
                case .visa:
                    guard let category = document.fields[.uscisCategory]?.text else { continue }
                    claims.append(claim(.plain("\(category) visa"), field: "status", in: document, date: window.start))
                default: continue
                }
            }
            guard !claims.isEmpty else { return }
            let floor = SimpleDate(year: 1800, month: 1, day: 1)!
            let sorted = claims.sorted { ($0.validFrom ?? $0.date ?? floor) > ($1.validFrom ?? $1.date ?? floor) }
            topics.append(KnowledgeTopic(
                id: "\(person)|state|status", person: person, name: "Immigration status", behavior: .state, current: sorted[0], others: Array(sorted.dropFirst()),
                note: sorted.count > 1 ? "Newest first: " + sorted.map { "\($0.value.spoken) from \(($0.validFrom ?? $0.date)?.display ?? "?")" }.joined(separator: ", ") + "." : nil,
                terms: KnowledgeTerms.terms(person: person, group: "Immigration status", label: "status visa category green card permanent resident", key: nil, value: sorted[0].value)
            ))
        }

        // MARK: Vaccines

        mutating func vaccineTopics(_ person: String, _ owned: [KnowledgeDocument]) {
            var doses: [String: [KnowledgeClaim]] = [:]
            for document in owned {
                for entry in document.entries where KnowledgeVaccines.isDose(entry) {
                    guard let family = KnowledgeVaccines.family(of: entry.label), let text = entry.value.text, let date = KnowledgeText.date(text) else { continue }
                    var item = claim(entry.value, field: entry.label, in: document, date: date, label: entry.label)
                    item.validFrom = nil
                    item.validUntil = nil
                    // The same dose copied onto a later record counts once.
                    if doses[family]?.contains(where: { $0.date == date }) == true { continue }
                    doses[family, default: []].append(item)
                }
            }
            for (family, claims) in doses {
                let sorted = claims.sorted { $0.date! > $1.date! }
                topics.append(KnowledgeTopic(
                    id: "\(person)|vaccine|\(family)", person: person, name: "Vaccinations · \(KnowledgeVaccines.displayName(family))", behavior: .event,
                    current: sorted[0], others: Array(sorted.dropFirst()), note: "\(sorted.count) dose\(sorted.count == 1 ? "" : "s") on file.",
                    terms: KnowledgeTerms.terms(person: person, group: "Vaccinations", label: KnowledgeVaccines.synonyms(family).joined(separator: " "), key: nil, value: .plain(""))
                        + ["shot", "shots", "vaccine", "vaccination", "vaccinated", "dose", "doses", "jab", "booster", "immunization"]
                ))
            }
        }

        // MARK: Travel

        mutating func travelTopics(_ person: String, _ owned: [KnowledgeDocument]) {
            let rows = owned.flatMap(\.travel)
            guard !rows.isEmpty else { return }
            var seen = Set<String>()
            let unique = rows.filter { seen.insert("\($0.date.iso)\($0.isArrival)").inserted }.sorted { $0.date < $1.date }
            var open: KnowledgeTravelRow?
            for row in unique {
                if !row.isArrival {
                    open = row
                } else if let departure = open {
                    trips.append(KnowledgeTrip(person: person, departure: departure.date, arrival: row.date, departurePort: departure.port, arrivalPort: row.port))
                    open = nil
                }
            }
            if let departure = open {
                trips.append(KnowledgeTrip(person: person, departure: departure.date, arrival: nil, departurePort: departure.port, arrivalPort: nil))
            }
            guard let source = owned.first(where: { !$0.travel.isEmpty }) else { return }
            let arrivals = unique.filter(\.isArrival).reversed().map { row in
                claim(.plain("\(row.date.iso) · \(row.port)"), field: "arrival", in: source, date: row.date)
            }
            if let last = arrivals.first {
                topics.append(KnowledgeTopic(
                    id: "\(person)|travel|arrival", person: person, name: "Travel · Last entry to the US", behavior: .event,
                    current: last, others: Array(arrivals.dropFirst()),
                    terms: KnowledgeTerms.terms(person: person, group: "Travel", label: "last entry entered arrived arrival came back returned us united states", key: nil, value: .plain(""))
                ))
            }
            let departures = unique.filter { !$0.isArrival }.reversed().map { row in
                claim(.plain("\(row.date.iso) · \(row.port)"), field: "departure", in: source, date: row.date)
            }
            if let last = departures.first {
                topics.append(KnowledgeTopic(
                    id: "\(person)|travel|trips", person: person, name: "Travel · Trips abroad", behavior: .event,
                    current: last, others: Array(departures.dropFirst()), note: "\(trips.filter { $0.person == person }.count) trips on file.",
                    terms: KnowledgeTerms.terms(person: person, group: "Travel", label: "trips trip abroad outside left departed departure travel traveled days", key: nil, value: .plain(""))
                ))
            }
        }
    }
}

// MARK: Vaccines

nonisolated enum KnowledgeVaccines {
    /// Vaccine families: a question about "tetanus" means Td, Tdap and DTaP doses too.
    static let families: [(id: String, name: String, words: [String])] = [
        ("tetanus", "Tetanus (Td, Tdap, DTaP)", ["tetanus", "td", "tdap", "dtap", "dt", "td/tdap", "diphtheria", "pertussis", "whooping"]),
        ("influenza", "Flu", ["influenza", "flu"]),
        ("covid", "COVID-19", ["covid", "covid-19", "sars-cov-2", "moderna", "pfizer", "novavax", "coronavirus"]),
        ("mmr", "MMR", ["mmr", "measles", "mumps", "rubella"]),
        ("hepatitisB", "Hepatitis B", ["hepatitis b", "hep b", "hepb", "hbv"]),
        ("hepatitisA", "Hepatitis A", ["hepatitis a", "hep a", "hepa"]),
        ("varicella", "Chickenpox (varicella)", ["varicella", "chickenpox", "chicken pox"]),
        ("hpv", "HPV", ["hpv", "gardasil"]),
        ("polio", "Polio", ["polio", "ipv", "opv"]),
        ("pneumococcal", "Pneumococcal", ["pneumococcal", "pcv", "prevnar", "pneumovax"]),
        ("shingles", "Shingles", ["shingles", "zoster", "shingrix"]),
        ("meningococcal", "Meningococcal", ["meningococcal", "menacwy", "menb"]),
        ("rotavirus", "Rotavirus", ["rotavirus"]),
        ("hib", "Hib", ["hib"]),
        ("rsv", "RSV", ["rsv"]),
    ]

    static func family(of label: String) -> String? {
        let lower = label.lowercased()
        let words = Set(KnowledgeText.words(lower))
        return families.first { family in
            family.words.contains { $0.contains(" ") || $0.contains("/") ? lower.contains($0) : words.contains($0) }
        }?.id
    }

    static func displayName(_ id: String) -> String { families.first { $0.id == id }?.name ?? id }
    static func synonyms(_ id: String) -> [String] { families.first { $0.id == id }?.words ?? [id] }

    /// A vaccine dose: an entry in a vaccination section, or one whose label names a vaccine, with a date and
    /// not a titer or a waiver.
    static func isDose(_ entry: KnowledgeEntry) -> Bool {
        guard entry.section != nil, entry.relation == nil, family(of: entry.label) != nil, let text = entry.value.text else { return false }
        let lower = text.lowercased()
        if lower.contains("titer") || lower.contains("immune") || lower.contains("waived") || lower.contains("not in season") { return false }
        let section = entry.section!.lowercased()
        let looksLikeVaccines = section.contains("vaccin") || section.contains("immuniz") || section.contains("immunis") || section.contains("shot")
        return looksLikeVaccines && KnowledgeText.date(text) != nil
    }
}
