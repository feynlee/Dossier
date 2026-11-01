import Foundation
import Observation
import os
import SwiftData

/// Keeps every document placed and named in the library: after documents are read, and once for documents
/// that were in Dossier before the library existed. Placements you set yourself are never changed.
@Observable
final class LibraryOrganizer {
    private(set) var isOrganizing = false

    @ObservationIgnored private let model = LibraryModel()
    @ObservationIgnored private let logger = Logger(subsystem: "liziyue.Dossier", category: "Library")
    /// The folders the model was last asked to lay out, so the same library isn't sent twice.
    @ObservationIgnored private var lastLayoutAsked: [LibraryPlanner.FolderSummary] = []

    func organize(context: ModelContext) async {
        guard !isOrganizing else { return }
        isOrganizing = true
        defer { isOrganizing = false }

        let documents = ((try? context.fetch(FetchDescriptor<SourceDocument>())) ?? [])
            .filter { $0.isReady && $0.kind != .addedByYou }
        let entries = documents.map(\.libraryEntry)

        // The model places documents of kinds without a rule, one at a time, seeing the folders so far.
        var folders = Set(documents.compactMap(\.placement).map { FolderKey(category: $0.category, folder: $0.folder) })
        var placed: [String: ModelPlacement] = [:]
        for entry in LibraryPlanner.needsModel(entries) {
            let existing = folders.sorted { ($0.category, $0.folder) < ($1.category, $1.folder) }
            guard let placement = await model.place(title: entry.facts.title, kind: entry.facts.kind.displayName, existing: existing) else { continue }
            placed[entry.id] = placement
            folders.insert(FolderKey(category: placement.category, folder: placement.folder))
        }

        var plan = LibraryPlanner.plan(entries, model: placed)
        let titles = Dictionary(documents.map { ($0.contentHash, $0.title) }, uniquingKeysWith: { first, _ in first })
        let summary = LibraryPlanner.summary(of: plan.filter { id, _ in !(entries.first { $0.id == id }?.isYours ?? false) }, titles: titles)
        if LibraryPlanner.needsNewLayout(summary), summary != lastLayoutAsked {
            lastLayoutAsked = summary
            let moves = await model.layout(summary)
            if !moves.isEmpty {
                logger.info("New library layout: \(moves.count, privacy: .public) folders move")
                plan = LibraryPlanner.plan(entries, model: placed, moves: moves)
            }
        }

        for document in documents where !document.isGone {
            if let placement = plan[document.contentHash], placement != document.placement {
                document.placement = placement
            }
        }
        try? context.save()
        await arrangeFiles(documents, showingPerson: LibraryPlanner.showsPeople(plan.values), context: context)
    }

    /// Files Dossier keeps itself, in iCloud Drive › Dossier, are moved and renamed to match the library.
    /// Your own files are never touched.
    private func arrangeFiles(_ documents: [SourceDocument], showingPerson: Bool, context: ModelContext) async {
        guard let root = await LibraryFolder.findRoot() else { return }
        for document in documents where !document.isGone {
            guard let placement = document.placement, let bookmark = document.bookmark,
                  let url = FileAccess.resolve(bookmark)?.url, LibraryFolder.contains(url, root: root)
            else { continue }
            let target = LibraryFolder.destination(for: placement, showingPerson: showingPerson, fileExtension: url.pathExtension.lowercased(), root: root)
            guard url.standardizedFileURL != target.standardizedFileURL else { continue }
            guard let moved = await Task.detached(priority: .utility, operation: { LibraryFolder.move(url, to: target) }).value,
                  moved.standardizedFileURL != url.standardizedFileURL
            else { continue }
            guard !document.isGone, let newBookmark = try? FileAccess.bookmark(for: moved) else { continue }
            document.bookmark = newBookmark
            document.fileName = moved.lastPathComponent
        }
        try? context.save()
    }

    /// Your own placement for a document. Dossier keeps it from now on.
    static func setYourPlacement(_ placement: LibraryPlacement, for document: SourceDocument) {
        document.placement = placement
        document.placementIsYours = true
    }

    /// Hands a document back to Dossier to place and name.
    static func resetPlacement(of document: SourceDocument) {
        document.placement = nil
        document.placementIsYours = false
    }
}

extension SourceDocument {
    var libraryEntry: LibraryEntry {
        LibraryEntry(id: contentHash, facts: libraryFacts, current: placement, isYours: placementIsYours)
    }

    /// The non-sensitive facts the library's names are made from.
    var libraryFacts: LibraryFacts {
        func text(_ key: FactKey) -> String? { fact(key).flatMap { VaultReader.value(of: $0) }?.nilIfEmpty }
        func date(_ key: FactKey) -> SimpleDate? { fact(key)?.plainDate.map { SimpleDate(utc: $0) } }
        let from: SimpleDate?
        let until: SimpleDate?
        var single: SimpleDate?
        switch kind {
        case .lease:
            from = date(.leaseStartDate); until = date(.leaseEndDate)
        case .employmentAuthorization:
            from = date(.validFrom) ?? date(.issueDate); until = date(.validUntil) ?? date(.expiryDate)
        case .uscisNotice:
            from = date(.validFrom); until = date(.validUntil); single = date(.noticeDate)
        case .i94:
            from = nil; until = date(.admitUntil)
        case .greenCard:
            from = date(.residentSince); until = date(.expiryDate)
        default:
            from = date(.issueDate); until = date(.expiryDate)
        }
        if from == nil, until == nil, single == nil { single = date(.noticeDate) ?? date(.issueDate) }
        return LibraryFacts(
            kind: kind,
            title: title,
            givenNames: text(.givenNames),
            surname: text(.surname),
            category: text(.uscisCategory),
            formType: text(.formType),
            address: text(.address),
            from: from,
            until: until,
            date: single,
            side: nil,
            fileExtension: (fileName as NSString).pathExtension.lowercased()
        )
    }
}
