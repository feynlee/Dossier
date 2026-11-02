import Foundation

/// One person as the library knows them: the documents about them and the name their folder goes by.
nonisolated struct PersonGroup: Equatable, Sendable {
    /// Entry ids, sorted.
    var members: [String]
    /// The first name their documents are filed under, such as "Ziyue".
    var firstName: String
    /// The family name in Latin letters, upper case, when the documents give one.
    var surname: String?
    var datesOfBirth: Set<SimpleDate>
    /// The given names as printed on each document, for the model.
    var printedNames: [String]
    var kinds: [DocumentKind]
    var titles: [String]
}

/// The model's answer: which groups are one person (numbered from 1), and the first name to use.
nonisolated struct PersonDecision: Codable, Equatable, Sendable {
    var numbers: [Int]
    var firstName: String
}

/// Works out who each document is about. The same person's given names are printed in different ways on
/// different documents: "ZIYUE" on a passport, "ZI YUE" on a form, "紫玥" on a Chinese document. Seen on a
/// real vault: the library made three people of them, Ziyue, Zi and 紫玥.
///
/// Rules first, which only join documents they're sure of:
/// - the same given names once written in Latin letters with the spaces taken out (Chinese characters become
///   pinyin, so 紫玥, Zi Yue and ZIYUE are all ZIYUE);
/// - one given name the start of the other ("ZI" and "ZIYUE"), when the family name or the birth date agrees;
/// - the same A-Number.
/// Documents with different birth dates or different family names are never joined. Then the on-device model
/// looks at the people left over, with their documents, and may join more (`applying(_:to:)` keeps only
/// joins and names that agree with the documents).
nonisolated enum PersonResolver {
    // MARK: Names in Latin letters

    static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    /// The text in Latin letters without accents: "紫玥" → "zi yue", "José" → "Jose".
    static func latin(_ text: String) -> String {
        var result = text
        if hasHan(result) { result = result.applyingTransform(.mandarinToLatin, reverse: false) ?? result }
        result = result.applyingTransform(.toLatin, reverse: false) ?? result
        return result.applyingTransform(.stripDiacritics, reverse: false) ?? result
    }

    /// Letters only, upper case: "Zi Yue" → "ZIYUE", "紫 玥" → "ZIYUE".
    static func key(_ text: String) -> String {
        String(latin(text).uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) }.map(Character.init))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }

    // MARK: Records

    private struct Record {
        var id: String
        var given: String
        var kind: DocumentKind
        var title: String
        /// The given names' key, and for a Chinese name of three or more characters the key without its first
        /// character too, in case the family name was printed with it ("李紫玥").
        var keys: [String]
        var surname: String?
        var dateOfBirth: SimpleDate?
        var identityKeys: Set<String>
    }

    private static func record(_ entry: LibraryEntry) -> Record? {
        guard !LibraryNaming.isHousehold(entry.facts.kind), let given = entry.facts.givenNames?.trimmingCharacters(in: .whitespaces),
              !key(given).isEmpty else { return nil }
        var keys = [key(given)]
        let han = given.filter { $0.unicodeScalars.contains { $0.properties.isIdeographic } }
        if han.count >= 3 { keys.append(key(String(han.dropFirst()))) }
        let surname = entry.facts.surname.map(key).flatMap { $0.isEmpty ? nil : $0 }
        return Record(id: entry.id, given: given, kind: entry.facts.kind, title: entry.facts.title, keys: keys, surname: surname,
                      dateOfBirth: entry.facts.dateOfBirth, identityKeys: Set(entry.facts.identityKeys))
    }

    private static func related(_ a: Record, _ b: Record) -> Bool {
        if !a.identityKeys.isDisjoint(with: b.identityKeys) { return true }
        if a.keys.contains(where: b.keys.contains) { return true }
        let sameSurname = a.surname != nil && a.surname == b.surname
        let sameBirth = a.dateOfBirth != nil && a.dateOfBirth == b.dateOfBirth
        guard sameSurname || sameBirth else { return false }
        return a.keys.contains { x in b.keys.contains { y in
            let (short, long) = x.count <= y.count ? (x, y) : (y, x)
            return short.count >= 2 && long.hasPrefix(short)
        } }
    }

    /// Whether documents may be one person's: at most one birth date and one family name among them.
    private static func compatible(_ records: [Record]) -> Bool {
        Set(records.compactMap(\.dateOfBirth)).count <= 1 && Set(records.compactMap(\.surname)).count <= 1
    }

    // MARK: Groups

    /// The people the documents are about, by the rules alone. Documents without a name, and leases, aren't in
    /// any group.
    static func groups(_ entries: [LibraryEntry]) -> [PersonGroup] {
        let records = entries.compactMap(record).sorted { $0.id < $1.id }
        var clusters = records.map { [$0] }
        var merged = true
        while merged {
            merged = false
            outer: for i in clusters.indices {
                for j in clusters.indices where j > i {
                    guard clusters[i].contains(where: { a in clusters[j].contains { related(a, $0) } }),
                          compatible(clusters[i] + clusters[j]) else { continue }
                    clusters[i] += clusters[j]
                    clusters.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return clusters.map(group).sorted { ($0.members.count, $1.firstName) > ($1.members.count, $0.firstName) }
    }

    private static func group(_ records: [Record]) -> PersonGroup {
        PersonGroup(
            members: records.map(\.id).sorted(),
            firstName: firstName(records),
            surname: records.compactMap(\.surname).first,
            datesOfBirth: Set(records.compactMap(\.dateOfBirth)),
            printedNames: records.map(\.given),
            kinds: records.map(\.kind),
            titles: records.map(\.title)
        )
    }

    /// The first name most of the documents agree on. A Chinese name, or a name printed without spaces,
    /// is one name; a name printed with spaces is first name and middle names ("MEI LING" → Mei), unless
    /// another document shows the spaced syllables as one name ("ZI YUE" with "ZIYUE" or "紫玥" → Ziyue).
    private static func firstName(_ records: [Record]) -> String {
        if records.allSatisfy({ hasHan($0.given) }) {
            // Only Chinese names: keep the characters.
            return mostCommon(records.map { String($0.given.filter { !$0.isWhitespace }) }) ?? "Me"
        }
        // A Chinese name is written in pinyin, as the Latin documents write it.
        let latinKeys = Set(records.filter { !hasHan($0.given) }.flatMap(\.keys))
        func hanKey(_ record: Record) -> String { record.keys.first(where: latinKeys.contains) ?? record.keys[0] }

        // Names that are one name: Chinese names, and names printed without spaces.
        var written: [String: String] = [:]
        for record in records {
            let parts = tokens(latin(record.given))
            if hasHan(record.given) {
                let name = hanKey(record)
                written[name] = written[name] ?? name.capitalized
            } else if parts.count == 1 {
                written[record.keys[0]] = written[record.keys[0]] ?? parts[0].lowercased().capitalized
            }
        }
        let wholeNames = Set(written.keys)
        var votes: [String] = []
        for record in records {
            let parts = tokens(latin(record.given))
            if hasHan(record.given) {
                votes.append(hanKey(record))
            } else if parts.count > 1, !wholeNames.contains(record.keys[0]) {
                let first = key(parts[0])
                written[first] = written[first] ?? parts[0].lowercased().capitalized
                votes.append(first)
            } else {
                votes.append(record.keys[0])
            }
        }
        guard let best = mostCommon(votes) else { return "Me" }
        return written[best] ?? best.capitalized
    }

    /// The most common value; ties go to the first in alphabetical order.
    private static func mostCommon(_ values: [String]) -> String? {
        Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: The model's review

    /// Groups after the model's decisions. A join is kept only when the documents allow it (one birth date,
    /// one family name); a first name only when it is one of the names on the person's documents.
    static func applying(_ decisions: [PersonDecision], to groups: [PersonGroup], entries: [LibraryEntry]) -> [PersonGroup] {
        let records = Dictionary(entries.compactMap(record).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<Int>()
        var result: [PersonGroup] = []
        for decision in decisions {
            let numbers = decision.numbers.filter { groups.indices.contains($0 - 1) && !used.contains($0) }
            guard !numbers.isEmpty else { continue }
            let members = numbers.flatMap { groups[$0 - 1].members }
            let memberRecords = members.compactMap { records[$0] }
            let parts: [[String]]
            if numbers.count > 1, compatible(memberRecords) {
                parts = [members]
            } else {
                parts = numbers.map { groups[$0 - 1].members }
            }
            used.formUnion(numbers)
            for part in parts {
                let partRecords = part.compactMap { records[$0] }
                var merged = group(partRecords)
                if let name = acceptedName(decision.firstName, for: partRecords) { merged.firstName = name }
                result.append(merged)
            }
        }
        for (index, kept) in groups.enumerated() where !used.contains(index + 1) { result.append(kept) }
        return result
    }

    /// The model's first name, written neatly, when it is one of the person's given names or all of them
    /// run together ("Ziyue" for "ZI YUE").
    private static func acceptedName(_ name: String, for records: [Record]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let wanted = key(trimmed)
        guard !wanted.isEmpty, trimmed.count <= 30 else { return nil }
        let allowed = Set(records.flatMap { record in record.keys + tokens(latin(record.given)).map(key) })
        guard allowed.contains(wanted) else { return nil }
        if hasHan(trimmed) { return String(trimmed.filter { !$0.isWhitespace }) }
        let letters = trimmed.filter { !$0.isWhitespace }
        return letters == letters.uppercased() || letters == letters.lowercased() ? letters.lowercased().capitalized : letters
    }

    // MARK: Folder names

    /// Each document's person folder name, by entry id. Two people with the same first name are told apart
    /// by the initial of their family name.
    static func names(for groups: [PersonGroup]) -> [String: String] {
        let counts = Dictionary(groups.map { ($0.firstName, 1) }, uniquingKeysWith: +)
        var result: [String: String] = [:]
        for group in groups {
            var name = group.firstName
            if counts[name, default: 0] > 1, let initial = group.surname?.first { name += " \(initial)" }
            for member in group.members { result[member] = name }
        }
        return result
    }

    /// A stable description of the groups, so the model is asked again only when they change.
    static func signature(of groups: [PersonGroup]) -> String {
        groups.map { group in
            [group.members.joined(separator: ","), group.printedNames.sorted().joined(separator: ","), group.surname ?? "",
             group.datesOfBirth.map(\.iso).sorted().joined(separator: ",")].joined(separator: "|")
        }.joined(separator: "\n")
    }
}
