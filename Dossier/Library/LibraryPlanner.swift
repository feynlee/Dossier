import Foundation

/// One document as the planner sees it.
nonisolated struct LibraryEntry: Sendable, Equatable {
    var id: String
    var facts: LibraryFacts
    var current: LibraryPlacement?
    var isYours = false
}

/// The model's choice for a document of a kind Dossier has no rule for.
nonisolated struct ModelPlacement: Sendable, Equatable {
    var category: String
    var folder: String
    /// The document's type in a few words, such as "I-20" or "Vaccination record".
    var type: String
    var detail: String?
}

/// A folder by its category and name.
nonisolated struct FolderKey: Hashable, Sendable {
    var category: String
    var folder: String
}

/// Places and names documents. Pure: the model's answers come in as arguments, so this is what the tests
/// cover.
nonisolated enum LibraryPlanner {
    /// Whose library this mainly is: the person on the most documents. Documents with no name on them go to
    /// this person.
    static func owner(of entries: [LibraryEntry], people: [String: String]? = nil) -> String? {
        let people = people ?? PersonResolver.names(for: PersonResolver.groups(entries))
        let names = entries.compactMap { people[$0.id] }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// The person folder: the holder's first name as `PersonResolver` settles it across all their documents,
    /// the owner's for a document without a name, Household for a lease. Two people with the same first name
    /// are told apart by the initial of their surname.
    static func person(for entry: LibraryEntry, owner: String?, among entries: [LibraryEntry], people: [String: String]? = nil) -> String {
        if LibraryNaming.isHousehold(entry.facts.kind) { return LibraryPlacement.household }
        let people = people ?? PersonResolver.names(for: PersonResolver.groups(entries))
        return people[entry.id] ?? owner ?? "Me"
    }

    /// Whether the library has documents for more than one person, so the person level is shown.
    static func showsPeople(_ placements: some Collection<LibraryPlacement>) -> Bool {
        Set(placements.map(\.person).filter { $0 != LibraryPlacement.household }).count > 1
    }

    /// Entries the model has to place: kinds without a rule that have no placement yet.
    static func needsModel(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.filter { !$0.isYours && $0.current == nil && LibraryNaming.rule(for: $0.facts.kind) == nil }
    }

    /// Placement for every entry. Yours are kept as they are. Others keep their folder (after any `moves`
    /// from a new layout) and get their name worked out again, so a corrected date shows in the name.
    static func plan(
        _ entries: [LibraryEntry],
        model: [String: ModelPlacement],
        moves: [FolderKey: FolderKey] = [:],
        people: [String: String]? = nil
    ) -> [String: LibraryPlacement] {
        let people = people ?? PersonResolver.names(for: PersonResolver.groups(entries))
        let mainPerson = owner(of: entries, people: people)
        var result: [String: LibraryPlacement] = [:]
        var taken: [FolderKey: Set<String>] = [:]

        for entry in entries where entry.isYours {
            guard let current = entry.current else { continue }
            result[entry.id] = current
            taken[FolderKey(category: current.category, folder: current.folder), default: []].insert(current.name)
        }

        for entry in entries where !entry.isYours {
            let holder = person(for: entry, owner: mainPerson, among: entries, people: people)
            var key: FolderKey
            var baseName: String
            if let rule = LibraryNaming.rule(for: entry.facts.kind) {
                key = FolderKey(category: entry.current?.category ?? rule.category, folder: entry.current?.folder ?? rule.folder)
                baseName = LibraryNaming.name(for: entry.facts, person: holder)
            } else if let placed = model[entry.id] {
                key = FolderKey(category: placed.category, folder: placed.folder)
                let detail = placed.detail.flatMap { LibraryNaming.mayRevealNumber($0) ? nil : $0 }
                baseName = LibraryNaming.name(for: entry.facts, person: holder, type: placed.type, detail: detail ?? "")
            } else if let current = entry.current {
                key = FolderKey(category: current.category, folder: current.folder)
                // The model's name from earlier, with the person brought up to date.
                let rest = current.name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                    .replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
                baseName = rest.isEmpty ? holder : "\(holder) · \(rest)"
            } else {
                // No model available: keep it findable until the model can place it.
                key = FolderKey(category: "Other", folder: "Documents")
                baseName = LibraryNaming.name(for: entry.facts, person: holder, type: entry.facts.title, detail: "")
            }
            if let moved = moves[key] { key = moved }
            key = FolderKey(category: LibraryNaming.clean(key.category), folder: LibraryNaming.clean(key.folder))
            let name = LibraryNaming.unique(baseName, among: taken[key, default: []])
            taken[key, default: []].insert(name)
            result[entry.id] = LibraryPlacement(person: holder, category: key.category, folder: key.folder, name: name)
        }
        return result
    }

    // MARK: Layout

    /// The folders in use, with how many documents each holds and a few of their titles, for the model.
    struct FolderSummary: Sendable, Equatable {
        var key: FolderKey
        var count: Int
        var examples: [String]
    }

    static func summary(of placements: [String: LibraryPlacement], titles: [String: String]) -> [FolderSummary] {
        var folders: [FolderKey: [String]] = [:]
        for (id, placement) in placements {
            folders[FolderKey(category: placement.category, folder: placement.folder), default: []].append(titles[id] ?? placement.name)
        }
        return folders.map { FolderSummary(key: $0.key, count: $0.value.count, examples: Array(Set($0.value).sorted().prefix(3))) }
            .sorted { ($0.key.category, $0.key.folder) < ($1.key.category, $1.key.folder) }
    }

    static let maxCategories = 8
    static let maxPerCategory = 40

    /// Whether the top level has outgrown its shape: too many categories, one that's crowded, or several that
    /// hold a single document.
    static func needsNewLayout(_ folders: [FolderSummary]) -> Bool {
        let perCategory = Dictionary(folders.map { ($0.key.category, $0.count) }, uniquingKeysWith: +)
        let singles = perCategory.values.filter { $0 == 1 }.count
        return perCategory.count > maxCategories || perCategory.values.contains { $0 > maxPerCategory } || (perCategory.count > 4 && singles >= 3)
    }

    /// Keeps a layout's moves only where they make sense: every folder gets a short, non-empty name, and the
    /// top level stays within `maxCategories`. Otherwise nothing moves.
    static func validated(_ moves: [FolderKey: FolderKey], for folders: [FolderSummary]) -> [FolderKey: FolderKey] {
        let cleaned = moves.compactMapValues { target -> FolderKey? in
            let category = LibraryNaming.clean(target.category), folder = LibraryNaming.clean(target.folder)
            guard !category.isEmpty, !folder.isEmpty, category.count <= 24, folder.count <= 32 else { return nil }
            return FolderKey(category: category, folder: folder)
        }
        let after = Set(folders.map { (cleaned[$0.key] ?? $0.key).category })
        return after.count <= maxCategories ? cleaned.filter { $0.key != $0.value } : [:]
    }
}
