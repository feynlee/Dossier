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
        reread([document], context: context, preferPrivateCloud: preferPrivateCloud)
    }

    /// Reads documents again from their files, replacing what was read. Facts you confirmed need confirming
    /// again.
    func reread(_ documents: [SourceDocument], context: ModelContext, preferPrivateCloud: Bool) {
        for document in documents where document.bookmark != nil {
            document.state = .queued
            document.failureReason = nil
        }
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
        await checkSources(documents)
        markChangedFiles(documents)
        var queue = documents.filter { [.queued, .downloading, .reading].contains($0.state) }
        var waiting = 0

        while !queue.isEmpty, !Task.isCancelled {
            let document = queue.removeFirst()
            // Removed from the vault while waiting.
            guard !document.isGone else { continue }
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
                guard !document.isGone else { continue }
                if let other = documents.first(where: { $0 !== document && $0.contentHash == loaded.hash && !$0.isGone }) {
                    // An exact copy of a file already in the vault, in another place. Ask which file to keep
                    // as the source; there's nothing new to read.
                    document.state = .awaitingDecision
                    document.decisionRaw = "duplicate"
                    document.relatedHash = other.contentHash
                    document.kindRaw = other.kindRaw
                    document.title = other.title
                    try? context.save()
                    continue
                }
                let pages = try await PageReader.read(loaded.data, fileName: document.fileName)
                guard !pages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                let (reading, engine) = try await extractor.extract(pages: pages, preferPrivateCloud: preferPrivateCloud)
                lastEngine = engine
                // Removed from the vault while it was being read: drop the result.
                guard !document.isGone else { continue }
                try save(reading, engine: engine, pages: pages, hash: loaded.hash, info: info, into: document, context: context)
                classify(document, among: documents)
                try? context.save()
            } catch {
                guard !document.isGone else { continue }
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

        // Fingerprints for spotting another file of the same document later, taken while the values are in
        // the clear. Only fingerprints are stored.
        var values: [FactKey: String] = [:]
        for item in verified where values[item.key] == nil { values[item.key] = item.value }
        let rows = kind == .i94 ? reading.travel.map { "\($0.date) \($0.kind) \($0.port.uppercased())" } : []
        let plain = DocumentIdentity.plainKeys(kind: kind, values: values, travel: rows)
        document.identityKey = try plain.identity.map { try sealer.fingerprint($0).base64EncodedString() }
        document.versionKey = try plain.version.map { try sealer.fingerprint($0).base64EncodedString() }
        document.contentSignature = try sealer.fingerprint(plain.signature).base64EncodedString()

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

    // MARK: Same document, several files

    /// Compares a newly read document with the rest of the vault. A duplicate or an update waits for you to
    /// choose; a renewal (same number, new dates) is simply another document.
    private func classify(_ document: SourceDocument, among documents: [SourceDocument]) {
        guard document.keys.identity != nil else { return }
        var found: (match: DocumentMatch, other: SourceDocument)?
        for other in documents where other !== document && !other.isGone && other.isReady && other.kind == document.kind {
            guard !document.keptAlongside.contains(other.contentHash), !other.keptAlongside.contains(document.contentHash) else { continue }
            let match = DocumentIdentity.match(document.keys, against: other.keys)
            if match == .duplicate { found = (match, other); break }
            if match == .update, found == nil { found = (match, other) }
        }
        guard let found else { return }
        document.state = .awaitingDecision
        document.decisionRaw = found.match == .duplicate ? "duplicate" : "update"
        document.relatedHash = found.other.contentHash
    }

    enum Decision {
        /// Duplicate: keep the file already in the vault; forget the new one.
        case keepExisting
        /// Duplicate: use the new file as the source, keeping everything already confirmed.
        case useNewFile
        /// Update: the new file replaces the old document.
        case replace
        /// Update: keep both as separate documents.
        case keepBoth
        /// Update: don't add the new file.
        case discardNew
    }

    func resolve(_ document: SourceDocument, with decision: Decision, context: ModelContext) {
        let other = document.relatedHash.flatMap { hash in
            try? context.fetch(FetchDescriptor<SourceDocument>(predicate: #Predicate { $0.contentHash == hash })).first
        }
        switch decision {
        case .keepExisting, .discardNew:
            context.delete(document)
        case .useNewFile:
            if let other {
                // Same content, so the facts (and anything you confirmed) stay; only the source changes.
                let (bookmark, name, size, modified, hash) = (document.bookmark, document.fileName, document.fileSize, document.fileModifiedAt, document.contentHash)
                context.delete(document)
                try? context.save()
                other.bookmark = bookmark
                other.fileName = name
                other.fileSize = size
                other.fileModifiedAt = modified
                other.contentHash = hash
                other.sourceMissing = false
            } else {
                finishDecision(document)
            }
        case .replace:
            if let other { context.delete(other) }
            finishDecision(document)
        case .keepBoth:
            if let other { document.keptAlongside.append(other.contentHash) }
            finishDecision(document)
        }
        try? context.save()
    }

    // MARK: Removing

    /// Removes documents and everything read from them. The files themselves aren't touched. A file that was
    /// waiting for you to choose between it and a removed document becomes a document of its own.
    func remove(_ removed: [SourceDocument], context: ModelContext, preferPrivateCloud: Bool) {
        let hashes = Set(removed.map(\.contentHash))
        let all = (try? context.fetch(FetchDescriptor<SourceDocument>())) ?? []
        var requeued = false
        for document in all where document.state == .awaitingDecision && !hashes.contains(document.contentHash) {
            guard let related = document.relatedHash, hashes.contains(related) else { continue }
            if document.decision == .duplicate {
                // An exact copy isn't read until you choose, so read it now.
                finishDecision(document)
                document.state = .queued
                requeued = true
            } else {
                finishDecision(document)
            }
        }
        for document in removed { context.delete(document) }
        try? context.save()
        if requeued { start(context: context, preferPrivateCloud: preferPrivateCloud) }
    }

    /// Removes every document, everything read from them, your edits, and the encryption keys, so nothing
    /// Dossier stored can be read again. The files themselves aren't touched.
    func removeAll(context: ModelContext) {
        cancel()
        Self.deleteAllRecords(context: context)
        VaultKeys.shared.destroyAll()
        FolderAccess.forgetLegacyFolders()
        unsupportedFiles = []
        duplicates = []
        lastEngine = nil
    }

    /// Deleted one by one, not with a batch delete, so screens showing these records update instead of
    /// reading records that no longer exist.
    static func deleteAllRecords(context: ModelContext) {
        for document in (try? context.fetch(FetchDescriptor<SourceDocument>())) ?? [] { context.delete(document) }
        for fact in (try? context.fetch(FetchDescriptor<Fact>())) ?? [] { context.delete(fact) }
        for event in (try? context.fetch(FetchDescriptor<TravelEvent>())) ?? [] { context.delete(event) }
        for override in (try? context.fetch(FetchDescriptor<ProfileOverride>())) ?? [] { context.delete(override) }
        try? context.save()
    }

    private func finishDecision(_ document: SourceDocument) {
        document.state = .ready
        document.decisionRaw = nil
        document.relatedHash = nil
    }

    // MARK: Source files

    /// Notices files that were deleted, and follows files that were moved: a bookmark resolves to a moved or
    /// renamed file's new location, which is saved.
    private func checkSources(_ documents: [SourceDocument]) async {
        for document in documents {
            guard let bookmark = document.bookmark else {
                document.sourceMissing = !document.relativePath.isEmpty
                continue
            }
            let status = await Self.sourceStatus(bookmark)
            if !status.missing { document.missingAcknowledged = false }
            document.sourceMissing = status.missing
            if let refreshed = status.refreshed { document.bookmark = refreshed }
        }
    }

    /// Gives a document a new source file (after its file was removed) and reads it again.
    func attach(_ url: URL, to document: SourceDocument, context: ModelContext, preferPrivateCloud: Bool) throws {
        document.bookmark = try FileAccess.bookmark(for: url)
        document.fileName = url.lastPathComponent
        document.sourceMissing = false
        document.missingAcknowledged = false
        document.state = .queued
        try context.save()
        start(context: context, preferPrivateCloud: preferPrivateCloud)
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
    private static func sourceStatus(_ bookmark: Data) async -> (missing: Bool, refreshed: Data?) {
        guard let resolved = FileAccess.resolve(bookmark) else { return (true, nil) }
        return (!FileAccess.exists(resolved.url), resolved.refreshed)
    }

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
