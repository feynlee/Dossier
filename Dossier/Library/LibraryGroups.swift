import Foundation

/// The Vault's sections: one per category, each holding the folders of the person you're looking at. Pure,
/// so the grouping is tested without SwiftData.
nonisolated enum LibraryGroups {
    struct Folder<Item>: Identifiable {
        var name: String
        var items: [Item]
        var id: String { name }
    }

    struct Section<Item>: Identifiable {
        var category: String
        /// Set when the section holds Household documents shown with one person's.
        var isShared: Bool
        var folders: [Folder<Item>]
        var id: String { isShared ? "\(category) · shared" : category }
    }

    /// Whose vault this mainly is: the person with the most documents. Ties go to the name first in order.
    static func owner(_ placements: [LibraryPlacement]) -> String? {
        let counts = Dictionary(placements.filter { $0.person != LibraryPlacement.household }.map { ($0.person, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// The people to switch between: the owner first, then others by name, then Household.
    static func people(_ placements: [LibraryPlacement], owner: String?) -> [String] {
        let names = Set(placements.map(\.person))
        let people = names.filter { $0 != LibraryPlacement.household }.sorted { a, b in
            if a == owner { return true }
            if b == owner { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return names.contains(LibraryPlacement.household) ? people + [LibraryPlacement.household] : people
    }

    /// Sections for one person (their documents, then shared ones) or for everyone (nil). In each folder, the
    /// documents in use come first by name, then expired and renewed ones, most recently ended first. Folders
    /// where every document has ended go after the others.
    static func sections<Item>(
        _ items: [(item: Item, placement: LibraryPlacement)], person: String?,
        status: (Item) -> DocumentLifecycle.Status = { _ in .current }
    ) -> [Section<Item>] {
        let shown = items.filter { person == nil || $0.placement.person == person || $0.placement.person == LibraryPlacement.household }
        let isShared = { (placement: LibraryPlacement) in
            person != nil && person != LibraryPlacement.household && placement.person == LibraryPlacement.household
        }
        let grouped = Dictionary(grouping: shown) { SectionKey(category: $0.placement.category, isShared: isShared($0.placement)) }
        return grouped.map { key, items in
            let folders = Dictionary(grouping: items, by: \.placement.folder)
                .map { Folder(name: $0.key, items: ordered($0.value, status: status)) }
                .sorted { a, b in
                    let x = a.items.allSatisfy { status($0).isEnded }, y = b.items.allSatisfy { status($0).isEnded }
                    if x != y { return !x }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            return Section(category: key.category, isShared: key.isShared, folders: folders)
        }
        .sorted { ($0.isShared ? 1 : 0, categoryOrder($0.category), $0.category) < ($1.isShared ? 1 : 0, categoryOrder($1.category), $1.category) }
    }

    /// One folder's documents: in use by name, then ended ones, most recently ended first.
    static func ordered<Item>(_ items: [(item: Item, placement: LibraryPlacement)], status: (Item) -> DocumentLifecycle.Status) -> [Item] {
        let byName = items.sorted { $0.placement.name.localizedStandardCompare($1.placement.name) == .orderedAscending }.map(\.item)
        return DocumentLifecycle.ordered(byName, status: status, ended: { status($0).endedOn })
    }

    /// Starter categories in their usual order, any others after them, Other last.
    static func categoryOrder(_ category: String) -> Int {
        if category == "Other" { return Int.max }
        return LibraryNaming.starterCategories.firstIndex(of: category) ?? LibraryNaming.starterCategories.count
    }

    private struct SectionKey: Hashable {
        var category: String
        var isShared: Bool
    }

    /// "2019 to 2022", or one year, from the documents' dates.
    static func years(_ dates: [SimpleDate]) -> String? {
        guard let first = dates.map(\.year).min(), let last = dates.map(\.year).max() else { return nil }
        return first == last ? "\(first)" : "\(first) to \(last)"
    }
}

extension Array where Element == SourceDocument {
    /// The documents that are yours: the owner's, the household's and ones not sorted yet. Family members'
    /// documents are theirs, so they don't count for your personal information or timeline.
    var owners: [SourceDocument] {
        guard let owner = LibraryGroups.owner(compactMap(\.placement)) else { return self }
        return filter { document in
            guard let person = document.placement?.person else { return true }
            return person == owner || person == LibraryPlacement.household
        }
    }
}
