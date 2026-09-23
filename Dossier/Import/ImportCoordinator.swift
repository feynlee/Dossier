import Foundation
import Observation
import os
import SwiftData

/// Runs the import pipeline over the documents folder: list files, skip ones already read, then for each new
/// file read its pages locally, extract with PCC, verify, and save sealed facts.
@Observable
final class ImportCoordinator {
    enum Phase: Equatable {
        case idle
        case listing
        case reading(done: Int, total: Int)
        case finished(added: Int, failed: Int)
    }

    private(set) var phase = Phase.idle
    private(set) var waitingForDownload = 0
    /// File name → why it couldn't be read, for the last run.
    private(set) var failures: [String: String] = [:]
    private(set) var lastEngine: ExtractionEngine?
    private(set) var errorMessage: String?

    var isRunning: Bool {
        switch phase {
        case .listing, .reading: true
        default: false
        }
    }

    @ObservationIgnored private let extractor = DocumentExtractor()
    @ObservationIgnored private let sealer = Sealer.shared
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "liziyue.Dossier", category: "Import")

    func start(context: ModelContext, preferPrivateCloud: Bool) {
        guard !isRunning else { return }
        task = Task { await run(context: context, preferPrivateCloud: preferPrivateCloud) }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    private func run(context: ModelContext, preferPrivateCloud: Bool) async {
        errorMessage = nil
        failures = [:]
        let folders = FolderAccess.folders()
        guard !folders.isEmpty else {
            errorMessage = FolderAccess.hasFolder
                ? "Your folders can’t be reached. Add them again in Settings › Folders."
                : "Add a folder to read your documents."
            phase = .idle
            return
        }
        adoptLegacyDocuments(into: folders, context: context)

        phase = .listing
        var files: [(folder: FolderAccess.Folder, file: FolderAccess.FolderFile)] = []
        var waiting = 0
        for folder in folders {
            do {
                let listing = try await Self.list(folder)
                files += listing.files.map { (folder, $0) }
                waiting += listing.waitingForDownload
            } catch {
                failures[folder.name] = "The folder couldn’t be opened: \(error.localizedDescription)"
            }
        }
        waitingForDownload = waiting

        let known = Set((try? context.fetch(FetchDescriptor<SourceDocument>()))?.map(\.contentHash) ?? [])
        var seen = Set<String>()
        var added = 0
        for (index, entry) in files.enumerated() {
            if Task.isCancelled { return }
            let file = entry.file
            phase = .reading(done: index, total: files.count)
            do {
                let loaded = try await Self.load(file, in: entry.folder.url)
                // The same file in two folders (or a folder inside another) is read once.
                guard !known.contains(loaded.hash), seen.insert(loaded.hash).inserted else { continue }
                let pages = try await PageReader.read(loaded.data, fileName: file.name)
                guard !pages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                let (reading, engine) = try await extractor.extract(pages: pages, preferPrivateCloud: preferPrivateCloud)
                lastEngine = engine
                try save(reading, engine: engine, pages: pages, file: file, hash: loaded.hash, in: context)
                added += 1
            } catch {
                logger.error("Couldn't read \(file.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
                failures[file.name] = error.localizedDescription
            }
        }
        phase = .finished(added: added, failed: failures.count)
    }

    // MARK: Saving

    private func save(_ reading: DocumentReading, engine: ExtractionEngine, pages: [ReadPage], file: FolderAccess.FolderFile, hash: String, in context: ModelContext) throws {
        let pageLines = pages.map(\.lines)
        let mrz = MRZParser.find(in: pageLines.flatMap { $0 })
        let license = pages.flatMap(\.barcodes).lazy.compactMap(AAMVAParser.parse).first

        let inputs = reading.fields.compactMap { field in
            FactKey(rawValue: field.key).map { Verifier.Input(key: $0, value: field.value, page: max(1, field.page)) }
        }
        let verified = Verifier.verify(inputs, pages: pageLines, mrz: mrz, license: license)

        let kind = DocumentKind(rawValue: reading.kind) ?? .other
        // Documents often print titles in capitals; the design system uses sentence case.
        let title = reading.title.isEmpty || reading.title == reading.title.uppercased() ? kind.displayName : reading.title
        let document = SourceDocument(
            contentHash: hash, fileName: file.name, relativePath: file.relativePath, folderID: file.folderID.uuidString,
            kind: kind, title: title, engine: engine, pageCount: pages.count
        )
        context.insert(document)

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
            if let alternate = item.alternate { fact.sealedAlternate = try sealer.seal(alternate, sensitive: item.key.isSensitive) }
            if let context = item.context, !item.key.isSensitive, !showsNumber(context) {
                fact.sealedContext = try sealer.seal(context, sensitive: false)
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

        for row in reading.travel {
            guard let date = SimpleDate(iso: row.date) else { continue }
            let event = TravelEvent(
                sealedDate: try sealer.seal(date.iso, sensitive: false),
                isArrival: row.kind == "arrival",
                sealedPort: try sealer.seal(row.port.uppercased(), sensitive: false)
            )
            event.document = document
            context.insert(event)
        }
        try context.save()
    }

    /// Documents read before Dossier supported several folders have no folder. With exactly one folder they
    /// can only have come from it.
    private func adoptLegacyDocuments(into folders: [FolderAccess.Folder], context: ModelContext) {
        guard folders.count == 1, let documents = try? context.fetch(FetchDescriptor<SourceDocument>()) else { return }
        var changed = false
        for document in documents where document.folderID.isEmpty && !document.relativePath.isEmpty {
            document.folderID = folders[0].id.uuidString
            changed = true
        }
        if changed { try? context.save() }
    }

    // MARK: Off the main actor

    @concurrent
    private static func list(_ folder: FolderAccess.Folder) async throws -> FolderAccess.Listing {
        try FolderAccess.list(folder)
    }

    @concurrent
    private static func load(_ file: FolderAccess.FolderFile, in folder: URL) async throws -> (data: Data, hash: String) {
        let data = try FolderAccess.read(file, in: folder)
        return (data, FolderAccess.contentHash(data))
    }
}
