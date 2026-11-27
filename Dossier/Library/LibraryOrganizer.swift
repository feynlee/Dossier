import CryptoKit
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
    /// Moves found by `proposeRefile`, waiting for you to review them. Nil when there's nothing to review.
    private(set) var refileMoves: [RefileMove]?
    /// True while `proposeRefile` asks the model about each document.
    private(set) var isCheckingRefile = false
    @ObservationIgnored private var refilePlan: [String: LibraryPlacement] = [:]

    func organize(context: ModelContext) async {
        guard !isOrganizing else { return }
        isOrganizing = true
        defer { isOrganizing = false }

        let documents = ((try? context.fetch(FetchDescriptor<SourceDocument>())) ?? [])
            .filter { $0.isReady && $0.kind != .addedByYou }
        let entries = documents.map(\.libraryEntry)

        let categories = CategoryList.current

        // The model places documents of kinds without a fixed place, one at a time, seeing the folders so far.
        var folders = Set(documents.compactMap(\.placement).map { FolderKey(category: $0.category, folder: $0.folder) })
        var placed: [String: ModelPlacement] = [:]
        for entry in LibraryPlanner.needsModel(entries, categories: categories) {
            let existing = folders.filter { categories.resolve($0.category) != nil }.sorted { ($0.category, $0.folder) < ($1.category, $1.folder) }
            guard let placement = await model.place(title: entry.facts.title, kind: entry.facts.kind.displayName, existing: existing, categories: categories) else { continue }
            placed[entry.id] = placement
            folders.insert(FolderKey(category: placement.category, folder: placement.folder))
        }

        let people = await resolvePeople(entries)
        let plan = LibraryPlanner.plan(entries, model: placed, people: people, categories: categories)

        for document in documents where !document.isGone {
            if let placement = plan[document.contentHash], placement != document.placement {
                document.placement = placement
            }
        }
        try? context.save()
        await arrangeFiles(documents, showingPerson: LibraryPlanner.showsPeople(plan.values), context: context)
    }

    // MARK: Refiling after you change your categories

    /// Works out where every document goes with your categories as they are now, asking the model again about
    /// each document without a fixed place. Sets `refileMoves` to the documents whose category changes. Your
    /// own placements never move.
    func proposeRefile(context: ModelContext) async {
        guard !isOrganizing, !isCheckingRefile else { return }
        isCheckingRefile = true
        defer { isCheckingRefile = false }
        refileMoves = nil

        let documents = ((try? context.fetch(FetchDescriptor<SourceDocument>())) ?? [])
            .filter { $0.isReady && $0.kind != .addedByYou && !$0.isGone }
        let entries = documents.map(\.libraryEntry)
        let categories = CategoryList.current

        var folders = Set(documents.compactMap(\.placement).compactMap { placement -> FolderKey? in
            categories.resolve(placement.category).map { FolderKey(category: $0, folder: placement.folder) }
        })
        var placed: [String: ModelPlacement] = [:]
        for entry in LibraryPlanner.needsModelForRefile(entries, categories: categories) {
            let existing = folders.sorted { ($0.category, $0.folder) < ($1.category, $1.folder) }
            guard let placement = await model.place(title: entry.facts.title, kind: entry.facts.kind.displayName, existing: existing, categories: categories) else { continue }
            placed[entry.id] = placement
            folders.insert(FolderKey(category: placement.category, folder: placement.folder))
        }
        let people = await resolvePeople(entries)
        let plan = LibraryPlanner.plan(entries, model: placed, people: people, categories: categories)
        refilePlan = plan
        refileMoves = Self.moves(documents: documents, plan: plan, categories: categories)
    }

    /// The documents whose category changes. A category you renamed isn't a move.
    static func moves(documents: [SourceDocument], plan: [String: LibraryPlacement], categories: CategoryList) -> [RefileMove] {
        documents.compactMap { document in
            guard !document.placementIsYours, let target = plan[document.contentHash] else { return nil }
            let from = document.libraryCategory
            if let from, (categories.resolve(from) ?? from) == target.category { return nil }
            return RefileMove(id: document.contentHash, title: document.libraryName ?? document.title, from: from, to: target)
        }
        .sorted { ($0.to.category, $0.title) < ($1.to.category, $1.title) }
    }

    /// Saves the reviewed plan: every document gets its new place, and files in iCloud Drive › Dossier move.
    func applyRefile(context: ModelContext) async {
        let plan = refilePlan
        refileMoves = nil
        refilePlan = [:]
        guard !plan.isEmpty else { return }
        let documents = ((try? context.fetch(FetchDescriptor<SourceDocument>())) ?? []).filter { $0.isReady && !$0.isGone }
        for document in documents where !document.placementIsYours {
            if let placement = plan[document.contentHash], placement != document.placement {
                document.placement = placement
            }
        }
        try? context.save()
        await arrangeFiles(documents, showingPerson: LibraryPlanner.showsPeople(plan.values), context: context)
    }

    /// Drops the reviewed plan. Renamed categories and ones you deleted are still sorted out, as on any pass.
    func keepCurrentShelves(context: ModelContext) async {
        refileMoves = nil
        refilePlan = [:]
        await organize(context: context)
    }

    /// Who each document is about. The rules group documents they're sure of; when that leaves more than one
    /// person, the on-device model reviews them with their documents. Its answer is kept until the people
    /// change, so it isn't asked on every pass.
    private func resolvePeople(_ entries: [LibraryEntry]) async -> [String: String] {
        var groups = PersonResolver.groups(entries)
        if groups.count > 1 {
            let signature = Self.hash(PersonResolver.signature(of: groups))
            var decisions = Self.savedPeopleReview(for: signature)
            if decisions == nil, let answer = await model.people(groups) {
                decisions = answer
                Self.savePeopleReview(answer, for: signature)
            }
            if let decisions {
                let reviewed = PersonResolver.applying(decisions, to: groups, entries: entries)
                if reviewed.count < groups.count { logger.info("People: \(groups.count, privacy: .public) found, \(reviewed.count, privacy: .public) after review") }
                groups = reviewed
            }
        }
        return PersonResolver.names(for: groups)
    }

    private static let peopleReviewKey = "libraryPeopleReview"

    nonisolated private struct PeopleReview: Codable {
        var signature: String
        var decisions: [PersonDecision]
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func savedPeopleReview(for signature: String) -> [PersonDecision]? {
        guard let data = UserDefaults.standard.data(forKey: peopleReviewKey),
              let review = try? JSONDecoder().decode(PeopleReview.self, from: data), review.signature == signature else { return nil }
        return review.decisions
    }

    private static func savePeopleReview(_ decisions: [PersonDecision], for signature: String) {
        guard let data = try? JSONEncoder().encode(PeopleReview(signature: signature, decisions: decisions)) else { return }
        UserDefaults.standard.set(data, forKey: peopleReviewKey)
    }

    /// Every document has a file in iCloud Drive › Dossier, filed and named as in the library, so the folder
    /// holds the whole vault and another device can add it in one go. Files Dossier keeps there are moved and
    /// renamed to match. A file you added from one of your own folders is copied in, and Dossier uses the copy
    /// from then on; your file stays where it is, untouched.
    private func arrangeFiles(_ documents: [SourceDocument], showingPerson: Bool, context: ModelContext) async {
        guard let root = await LibraryFolder.findRoot() else { return }
        var copied = 0
        for document in documents where !document.isGone && !document.sourceMissing {
            guard let placement = document.placement, let bookmark = document.bookmark,
                  let url = FileAccess.resolve(bookmark)?.url else { continue }
            let target = LibraryFolder.destination(for: placement, showingPerson: showingPerson, fileExtension: url.pathExtension.lowercased(), root: root)
            let result: URL?
            if LibraryFolder.contains(url, root: root) {
                guard url.standardizedFileURL != target.standardizedFileURL else { continue }
                result = await Task.detached(priority: .utility, operation: { LibraryFolder.move(url, to: target) }).value
            } else {
                let modified = document.fileModifiedAt
                result = await Task.detached(priority: .utility, operation: { () -> URL? in
                    guard let data = try? FileAccess.read(url) else { return nil }
                    return LibraryFolder.copy(data, to: target, modified: modified)
                }).value
                if result != nil { copied += 1 }
            }
            guard let result, result.standardizedFileURL != url.standardizedFileURL,
                  !document.isGone, let newBookmark = try? FileAccess.bookmark(for: result) else { continue }
            document.bookmark = newBookmark
            document.fileName = result.lastPathComponent
            // The copy keeps the file's date, so it isn't taken for a changed file and read again.
            if let info = FileAccess.info(for: result) {
                document.fileModifiedAt = info.modified ?? document.fileModifiedAt
                if let size = info.size { document.fileSize = size }
            }
        }
        if copied > 0 { logger.info("Copied \(copied, privacy: .public) files into the Dossier folder") }
        try? context.save()
        await Task.detached(priority: .utility) { LibraryFolder.removeEmptyFolders(in: root) }.value
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
            fileExtension: (fileName as NSString).pathExtension.lowercased(),
            dateOfBirth: text(.dateOfBirth).flatMap(SimpleDate.init(iso:)),
            identityKeys: fact(.alienNumber)?.fingerprint.map { ["A|" + $0.base64EncodedString()] } ?? []
        )
    }
}

/// One document that moves to another category after you change your categories.
nonisolated struct RefileMove: Identifiable, Equatable, Sendable {
    /// The document's content hash.
    var id: String
    var title: String
    /// Its category before, as saved. Nil when it had no place yet.
    var from: String?
    var to: LibraryPlacement
}
