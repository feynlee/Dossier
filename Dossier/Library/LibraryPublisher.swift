import FileProvider
import Foundation
import os

/// Keeps the Dossier location in Files up to date: writes the library index and a copy of each document's
/// file to the app group, then tells Files to look again. The extension can't open your files through
/// Dossier's bookmarks, so it serves these copies.
nonisolated enum LibraryPublisher {
    struct Source: Sendable {
        var entry: LibraryIndex.Entry
        var bookmark: Data
    }

    private static let logger = Logger(subsystem: "liziyue.Dossier", category: "Library")
    static var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(LibraryIndex.domainIdentifier), displayName: "Dossier")
    }

    /// The documents with a place in the library, as Files will show them.
    @MainActor
    static func sources(_ documents: [SourceDocument]) -> [Source] {
        let placed = documents.filter { !$0.isGone && $0.isReady }
        let showingPerson = LibraryPlanner.showsPeople(placed.compactMap(\.placement))
        return placed.compactMap { document in
            guard let placement = document.placement, let bookmark = document.bookmark else { return nil }
            let ext = (document.fileName as NSString).pathExtension.lowercased()
            let entry = LibraryIndex.Entry(
                id: document.contentHash,
                path: placement.path(showingPerson: showingPerson),
                name: ext.isEmpty ? placement.name : "\(placement.name).\(ext)",
                size: 0,
                added: document.ingestedAt,
                modified: document.fileModifiedAt ?? document.ingestedAt
            )
            return Source(entry: entry, bookmark: bookmark)
        }
    }

    /// Copies files that are new or changed, removes copies no longer needed, and saves the index. Files is
    /// told only when something changed.
    @concurrent
    static func publish(_ sources: [Source]) async {
        // With nothing in the library, the location is taken out of Files.
        guard !sources.isEmpty else {
            if LibraryIndex.load() != nil { await remove() }
            return
        }
        guard let directory = LibraryIndex.filesDirectory else {
            logger.error("No app group container for the library")
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var entries: [LibraryIndex.Entry] = []
        for source in sources {
            if Task.isCancelled { return }
            guard let cached = copy(source, into: directory) else { continue }
            entries.append(cached)
        }

        let kept = Set(entries.compactMap { LibraryIndex.fileURL(for: $0)?.lastPathComponent })
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }

        let previous = LibraryIndex.load()
        let isNew = previous == nil
        if previous?.entries.sorted(by: { $0.id < $1.id }) != entries.sorted(by: { $0.id < $1.id }) {
            do {
                try LibraryIndex(entries: entries, updated: .now).save()
            } catch {
                logger.error("Couldn't save the library index: \(String(describing: error), privacy: .public)")
                return
            }
            await signal(registering: isNew)
        } else {
            await signal(registering: false)
        }
    }

    /// The entry with its copy in place, copying the file when the copy is missing or out of date. Nil when
    /// the file can't be read.
    private static func copy(_ source: Source, into directory: URL) -> LibraryIndex.Entry? {
        var entry = source.entry
        guard let target = LibraryIndex.fileURL(for: entry) else { return nil }
        let existing = try? target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let existing, let size = existing.fileSize, existing.contentModificationDate == entry.modified {
            entry.size = Int64(size)
            return entry
        }
        guard let url = FileAccess.resolve(source.bookmark)?.url, let data = try? FileAccess.read(url) else { return nil }
        do {
            try data.write(to: target, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.modificationDate: entry.modified], ofItemAtPath: target.path)
        } catch {
            logger.error("Couldn't copy a file for Files: \(String(describing: error), privacy: .public)")
            return nil
        }
        entry.size = Int64(data.count)
        return entry
    }

    /// Adds the Dossier location to Files the first time, then asks Files to enumerate it again.
    private static func signal(registering: Bool) async {
        do {
            let added = registering ? false : await isRegistered()
            if !added { try await NSFileProviderManager.add(domain) }
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        } catch {
            logger.error("Couldn't update the Dossier location in Files: \(String(describing: error), privacy: .public)")
        }
    }

    private static func isRegistered() async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier == domain.identifier }
    }

    /// Takes the Dossier location out of Files and deletes the copies, as when all data is deleted.
    static func remove() async {
        try? await NSFileProviderManager.remove(domain)
        if let container = LibraryIndex.container {
            try? FileManager.default.removeItem(at: container.appending(path: "Library/Caches/Library Files"))
            if let index = LibraryIndex.indexURL { try? FileManager.default.removeItem(at: index) }
        }
    }
}
