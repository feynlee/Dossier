import Foundation
import Observation
import os
import SwiftData

/// Reads the files you add to the vault, one at a time: download from iCloud if needed, read the pages
/// locally, extract with PCC, verify, and save one sealed result per file. Only files you added are read; a
/// file that changed since it was read is read again and its old result replaced.
@Observable
final class ImportCoordinator {
    private(set) var isRunning = false
    /// The document being read and how many are left, for progress.
    private(set) var current: (name: String, remaining: Int)?
    /// Files you picked that Dossier can't read (Word documents…), from the last add.
    private(set) var unsupportedFiles: [String] = []
    /// Files you added that were already in the vault, from the last add.
    private(set) var duplicates: [String] = []
    private(set) var lastEngine: ExtractionEngine?

    @ObservationIgnored private let extractor = DocumentExtractor()
    @ObservationIgnored private let sealer = Sealer.shared
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "liziyue.Dossier", category: "Import")

    /// How often to look again while iCloud is still downloading files: every 15 seconds for the first five
    /// minutes, then every minute until everything has arrived. Checks also run each time the app opens.
    static func recheckDelay(after rechecks: Int) -> Duration {
        rechecks < 20 ? .seconds(15) : .seconds(60)
    }

    // MARK: Adding

    /// Adds files you picked and starts reading them. Pass the folder when the files came from a folder you
    /// picked. Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], within folder: URL? = nil, context: ModelContext, preferPrivateCloud: Bool) -> Int {
        let existing = (try? context.fetch(FetchDescriptor<SourceDocument>())) ?? []
        let existingPaths = Set(existing.compactMap { $0.bookmark.flatMap(FileAccess.resolve)?.url.standardizedFileURL.path })
        unsupportedFiles = []
        duplicates = []
        var added = 0
        for url in urls {
            guard FileAccess.isReadable(url) else {
                unsupportedFiles.append(url.lastPathComponent)
                continue
            }
            guard !existingPaths.contains(url.standardizedFileURL.path) else {
                duplicates.append(url.lastPathComponent)
                continue
            }
            do {
                let bookmark = try FileAccess.bookmark(for: url, within: folder)
                context.insert(SourceDocument.pending(fileName: url.lastPathComponent, bookmark: bookmark))
                added += 1
            } catch {
                logger.error("Couldn't bookmark a file: \(error.localizedDescription, privacy: .public)")
                unsupportedFiles.append(url.lastPathComponent)
            }
        }
        try? context.save()
        start(context: context, preferPrivateCloud: preferPrivateCloud)
        return added
    }

    /// Reads a document again from its file.
    func reread(_ document: SourceDocument, context: ModelContext, preferPrivateCloud: Bool) {
        document.state = .queued
        document.failureReason = nil
        try? context.save()
        start(context: context, preferPrivateCloud: preferPrivateCloud)
    }

    // MARK: Processing

    func start(context: ModelContext, preferPrivateCloud: Bool) {
        guard !isRunning else { return }
        task?.cancel()
        task = Task {
            var rechecks = 0
            while !Task.isCancelled {
                let waiting = await run(context: context, preferPrivateCloud: preferPrivateCloud)
                guard waiting > 0 else { break }
                // Files still downloading from iCloud: look again until they arrive.
                try? await Task.sleep(for: Self.recheckDelay(after: rechecks))
                rechecks += 1
            }
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
        current = nil
    }

    /// One pass over the queue. Returns how many files are still downloading.
    private func run(context: ModelContext, preferPrivateCloud: Bool) async -> Int {
        isRunning = true
        defer {
            isRunning = false
            current = nil
        }
        migrateFolderDocuments(context: context)

        let documents = (try? context.fetch(FetchDescriptor<SourceDocument>(sortBy: [SortDescriptor(\.ingestedAt)]))) ?? []
        markChangedFiles(documents)
        var queue = documents.filter { [.queued, .downloading, .reading].contains($0.state) }
        var waiting = 0

        while !queue.isEmpty, !Task.isCancelled {
            let document = queue.removeFirst()
            guard let bookmark = document.bookmark, let resolved = FileAccess.resolve(bookmark) else {
                fail(document, "The file can’t be found. It may have been moved or deleted.")
                continue
            }
            if let refreshed = resolved.refreshed { document.bookmark = refreshed }
            let info = await Self.info(resolved.url)

            if let error = info?.downloadError {
                fail(document, "iCloud couldn’t download it: \(error)")
                continue
            }
            if info?.isDownloaded == false {
                await Self.requestDownload(resolved.url)
                document.state = .downloading
                waiting += 1
                continue
            }

            current = (document.fileName, queue.count)
            document.state = .reading
            try? context.save()
            do {
                let loaded = try await Self.load(resolved.url)
                if let other = documents.first(where: { $0 !== document && $0.contentHash == loaded.hash && !$0.isDeleted }) {
                    // The same file was already added (perhaps from another folder). Keep the older entry.
                    logger.notice("Duplicate of \(other.fileName, privacy: .private); removing the new entry")
                    duplicates.append(document.fileName)
                    context.delete(document)
                    try? context.save()
                    continue
                }
                let pages = try await PageReader.read(loaded.data, fileName: document.fileName)
                guard !pages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                let (reading, engine) = try await extractor.extract(pages: pages, preferPrivateCloud: preferPrivateCloud)
                lastEngine = engine
                try save(reading, engine: engine, pages: pages, hash: loaded.hash, info: info, into: document, context: context)
            } catch {
                logger.error("Couldn't read \(document.fileName, privacy: .private): \(error.localizedDescription, privacy: .public)")
                fail(document, error.localizedDescription)
            }
        }
        try? context.save()
        return waiting
    }

    private func fail(_ document: SourceDocument, _ reason: String) {
        document.state = .failed
        document.failureReason = reason
    }

    /// A file you edited since it was read is read again, so each file has one current result.
    private func markChangedFiles(_ documents: [SourceDocument]) {
        for document in documents where document.state == .ready {
            guard let bookmark = document.bookmark, let url = FileAccess.resolve(bookmark)?.url, let info = FileAccess.info(for: url),
                  let modified = info.modified, let before = document.fileModifiedAt else { continue }
            if abs(modified.timeIntervalSince(before)) >= 1 || (info.size != nil && info.size != document.fileSize && document.fileSize > 0) {
                document.state = .queued
            }
        }
    }

    // MARK: Saving

    /// Replaces the document's result with this reading: one result per file.
    private func save(
        _ reading: DocumentReading, engine: ExtractionEngine, pages: [ReadPage], hash: String, info: FileAccess.Info?,
        into document: SourceDocument, context: ModelContext
    ) throws {
        let pageLines = pages.map(\.lines)
        let mrz = MRZParser.find(in: pageLines.flatMap { $0 })
        let license = pages.flatMap(\.barcodes).lazy.compactMap(AAMVAParser.parse).first
        let kind = DocumentKind(rawValue: reading.kind) ?? .other

        // Only the important facts for this kind of document are kept.
        let important = Set(kind.importantKeys)
        let inputs = reading.fields.compactMap { field -> Verifier.Input? in
            guard let key = FactKey(rawValue: field.key), important.contains(key) else { return nil }
            return Verifier.Input(key: key, value: field.value, page: max(1, field.page), isConfident: field.confidence != "low")
        }
        let verified = Verifier.verify(inputs, pages: pageLines, mrz: mrz, license: license).filter { important.contains($0.key) }

        for fact in document.facts { context.delete(fact) }
        for event in document.travel { context.delete(event) }

        document.contentHash = hash
        document.kindRaw = kind.rawValue
        // Documents often print titles in capitals; the design system uses sentence case.
        document.title = reading.title.isEmpty || reading.title == reading.title.uppercased() ? kind.displayName : reading.title
        document.engineRaw = engine.rawValue
        document.pageCount = pages.count
        document.fileSize = info?.size ?? 0
        document.fileModifiedAt = info?.modified
        document.ingestedAt = .now

        // Lines that show a sensitive number: their text isn't stored and their crop needs Face ID.
        let showsNumber = { (line: String) in Verifier.line(line, showsAnyOf: verified) }

        for item in verified {
            let fact = Fact(
                key: item.key,
                sealedValue: try sealer.seal(item.value, sensitive: item.key.isSensitive),
                sealedHint: item.key.isSensitive ? try sealer.seal(String(item.value.suffix(4)), sensitive: false) : nil,
                status: item.status,
                check: item.check,
                page: item.page
            )
            if let profileKey = ProfileKey.allCases.first(where: { $0.factKey == item.key }), profileKey.isSensitive {
                fact.fingerprint = try sealer.fingerprint(Reconciler.normalize(item.value, for: profileKey))
            }
            if let alternate = item.alternate { fact.sealedAlternate = try sealer.seal(alternate, sensitive: item.key.isSensitive) }
            if let line = item.context, !item.key.isSensitive, !showsNumber(line) {
                fact.sealedContext = try sealer.seal(line, sensitive: false)
            }
            fact.cropRevealsNumber = item.context.map(showsNumber) ?? false
            // Only non-personal dates go in the clear, for sorting and expiry badges.
            if item.key.isDate, item.key != .dateOfBirth { fact.plainDate = SimpleDate(iso: item.value)?.date }
            if let location = item.location, pages.indices.contains(location.page), pages[location.page].boxes.indices.contains(location.line) {
                fact.setCrop(page: location.page + 1, rect: pages[location.page].boxes[location.line])
            }
            fact.document = document
            context.insert(fact)
        }

        for row in reading.travel where kind == .i94 {
            guard let date = SimpleDate(iso: row.date) else { continue }
            let event = TravelEvent(
                sealedDate: try sealer.seal(date.iso, sensitive: false),
                isArrival: row.kind == "arrival",
                sealedPort: try sealer.seal(row.port.uppercased(), sensitive: false)
            )
            event.document = document
            context.insert(event)
        }
        document.state = .ready
        document.failureReason = nil
        try context.save()
    }

    // MARK: Earlier versions

    /// Earlier versions found files through folders. Give each of those documents a bookmark to its own file,
    /// so it can be shown and re-read like a file you added.
    private func migrateFolderDocuments(context: ModelContext) {
        guard FolderAccess.hasLegacyFolders else { return }
        let folders = FolderAccess.legacyFolders()
        let documents = (try? context.fetch(FetchDescriptor<SourceDocument>())) ?? []
        for document in documents where document.bookmark == nil && !document.relativePath.isEmpty {
            let candidates = folders.filter { document.folderID.isEmpty || $0.id == document.folderID }
            for folder in candidates {
                let url = folder.url.appending(path: document.relativePath)
                if let bookmark = try? FileAccess.bookmark(for: url, within: folder.url),
                   FileAccess.resolve(bookmark) != nil {
                    document.bookmark = bookmark
                    break
                }
            }
        }
        try? context.save()
        FolderAccess.forgetLegacyFolders()
    }

    // MARK: Off the main actor

    @concurrent
    private static func info(_ url: URL) async -> FileAccess.Info? {
        FileAccess.info(for: url)
    }

    @concurrent
    private static func requestDownload(_ url: URL) async {
        FileAccess.requestDownload(url)
    }

    @concurrent
    private static func load(_ url: URL) async throws -> (data: Data, hash: String) {
        let data = try FileAccess.read(url)
        return (data, FileAccess.contentHash(data))
    }
}
