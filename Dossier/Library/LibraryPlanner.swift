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

    /// Whether folders start with the person. Always, even for one person (Li's choice, 2026-11-03): the
    /// layout then never changes when a second person's document arrives, so nothing is reshuffled under a
    /// device that imported the folder.
    static func showsPeople(_ placements: some Collection<LibraryPlacement>) -> Bool {
        !placements.isEmpty
    }

    /// The category a kind with a fixed place goes to, by its name now. Nil when the kind has no fixed place,
    /// or you deleted its category: then the model places it.
    static func ruleCategory(for kind: DocumentKind, in categories: CategoryList) -> String? {
        LibraryNaming.rule(for: kind).flatMap { categories.builtIn($0.category) }
    }

    /// Entries the model has to place: not yours, with no fixed place, and with no placement yet or one in a
    /// category that's no longer in your list.
    static func needsModel(_ entries: [LibraryEntry], categories: CategoryList = .current) -> [LibraryEntry] {
        entries.filter { entry in
            guard !entry.isYours, ruleCategory(for: entry.facts.kind, in: categories) == nil else { return false }
            guard let current = entry.current else { return true }
            return categories.resolve(current.category) == nil
        }
    }

    /// Entries a refile asks the model about again: not yours, and with no fixed place.
    static func needsModelForRefile(_ entries: [LibraryEntry], categories: CategoryList = .current) -> [LibraryEntry] {
        entries.filter { !$0.isYours && ruleCategory(for: $0.facts.kind, in: categories) == nil }
    }

    /// Placement for every entry. Yours are kept as they are. Others keep their folder (after any `moves`
    /// from a new layout) and get their name worked out again, so a corrected date shows in the name.
    static func plan(
        _ entries: [LibraryEntry],
        model: [String: ModelPlacement],
        moves: [FolderKey: FolderKey] = [:],
        people: [String: String]? = nil,
        categories: CategoryList = .current
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
            if let rule = LibraryNaming.rule(for: entry.facts.kind), let category = ruleCategory(for: entry.facts.kind, in: categories) {
                key = FolderKey(category: entry.current.flatMap { categories.resolve($0.category) } ?? category, folder: entry.current?.folder ?? rule.folder)
                baseName = LibraryNaming.name(for: entry.facts, person: holder)
            } else if let placed = model[entry.id] {
                key = FolderKey(category: categories.resolve(placed.category) ?? CategoryList.other, folder: placed.folder)
                let detail = placed.detail.flatMap { LibraryNaming.mayRevealNumber($0) ? nil : $0 }
                baseName = LibraryNaming.name(for: entry.facts, person: holder, type: placed.type, detail: detail ?? "")
            } else if let current = entry.current {
                key = FolderKey(category: categories.resolve(current.category) ?? current.category, folder: current.folder)
                // The model's name from earlier, with the person brought up to date.
                let rest = current.name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                    .replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
                baseName = rest.isEmpty ? holder : "\(holder) · \(rest)"
            } else {
                // No model available: keep it findable until the model can place it.
                key = FolderKey(category: CategoryList.other, folder: "Documents")
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
}
