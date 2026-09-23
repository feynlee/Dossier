import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The user's documents folders, remembered as bookmarks so Dossier can read them again on later launches.
/// Files are read in place and never copied.
nonisolated struct FolderAccess: Sendable {
    private static let foldersKey = "documentsFolders"
    /// Where the single folder of earlier versions was stored; migrated into `foldersKey` on first read.
    private static let legacyBookmarkKey = "documentsFolderBookmark"
    /// Where folder bookmarks are kept. Tests point this at a scratch suite.
    nonisolated(unsafe) static var store = UserDefaults.standard

    static let readableTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff]

    /// A folder you added.
    struct Folder: Identifiable, Hashable, Sendable {
        var id: UUID
        var url: URL

        var name: String { url.lastPathComponent }
        var displayPath: String { FolderAccess.displayPath(for: url) }
    }

    struct FolderFile: Sendable, Hashable {
        var url: URL
        var name: String
        /// Path inside its folder, such as "Immigration/I-797.pdf".
        var relativePath: String
        var folderID: UUID
    }

    struct Listing: Sendable {
        var files: [FolderFile]
        /// Files that are in iCloud but not downloaded yet. Dossier asks iCloud to download them and reads
        /// them on the next scan.
        var waitingForDownload: Int
    }

    private struct SavedFolder: Codable {
        var id: UUID
        var bookmark: Data
    }

    // MARK: Folders

    /// Every folder you added, in the order you added them. Folders whose bookmark no longer resolves (the
    /// folder was deleted or moved out of reach) are skipped until they come back.
    static func folders() -> [Folder] {
        var saved = savedFolders()
        var changed = false
        var result: [Folder] = []
        for (index, entry) in saved.enumerated() {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                continue
            }
            if isStale, let fresh = try? bookmark(for: url) {
                saved[index].bookmark = fresh
                changed = true
            }
            result.append(Folder(id: entry.id, url: url))
        }
        if changed { store(saved) }
        return result
    }

    static func folder(id: String) -> Folder? {
        folders().first { $0.id.uuidString == id }
    }

    static var hasFolder: Bool { !savedFolders().isEmpty }

    /// Adds a folder, or returns the existing one if you already added it.
    @discardableResult
    static func add(_ url: URL) throws -> Folder {
        if let existing = folders().first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            return existing
        }
        let entry = SavedFolder(id: UUID(), bookmark: try bookmark(for: url))
        store(savedFolders() + [entry])
        return Folder(id: entry.id, url: url)
    }

    static func remove(_ id: UUID) {
        store(savedFolders().filter { $0.id != id })
    }

    static func forgetAll() {
        store.removeObject(forKey: foldersKey)
        store.removeObject(forKey: legacyBookmarkKey)
    }

    private static func bookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func savedFolders() -> [SavedFolder] {
        let defaults = store
        if let data = defaults.data(forKey: foldersKey), let saved = try? JSONDecoder().decode([SavedFolder].self, from: data) {
            return saved
        }
        if let legacy = defaults.data(forKey: legacyBookmarkKey) {
            let migrated = [SavedFolder(id: UUID(), bookmark: legacy)]
            store(migrated)
            defaults.removeObject(forKey: legacyBookmarkKey)
            return migrated
        }
        return []
    }

    private static func store(_ folders: [SavedFolder]) {
        store.set(try? JSONEncoder().encode(folders), forKey: foldersKey)
    }

    /// "iCloud Drive › Documents › Personal"-style path for display.
    static func displayPath(for url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + components[(index + 1)...]).joined(separator: " › ")
        }
        if let index = components.firstIndex(of: "File Provider Storage") {
            return (["On My iPhone"] + components[(index + 1)...]).joined(separator: " › ")
        }
        return components.suffix(2).joined(separator: " › ")
    }

    // MARK: Listing

    /// Lists readable files in the folder and its subfolders, and starts downloads for iCloud placeholders.
    static func list(_ source: Folder) throws -> Listing {
        let folder = source.url
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var listing = Listing(files: [], waitingForDownload: 0)
        var enumerationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .withoutChanges, error: &coordinationError) { url in
            let keys: [URLResourceKey] = [.contentTypeKey, .isDirectoryKey, .ubiquitousItemDownloadingStatusKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
                return
            }
            for case let fileURL as URL in enumerator {
                do {
                    let values = try fileURL.resourceValues(forKeys: Set(keys))
                    if values.isDirectory == true { continue }

                    // iCloud placeholders look like ".Passport.pdf.icloud".
                    if fileURL.pathExtension == "icloud" {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                        listing.waitingForDownload += 1
                        continue
                    }
                    if let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                        listing.waitingForDownload += 1
                        continue
                    }
                    guard let type = values.contentType, readableTypes.contains(where: { type.conforms(to: $0) }) else { continue }
                    let root = url.standardizedFileURL.path
                    let path = fileURL.standardizedFileURL.path
                    let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : fileURL.lastPathComponent
                    listing.files.append(FolderFile(url: fileURL, name: fileURL.lastPathComponent, relativePath: relative, folderID: source.id))
                } catch {
                    enumerationError = error
                }
            }
        }
        if let error = coordinationError ?? (listing.files.isEmpty ? enumerationError as NSError? : nil) { throw error }
        listing.files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return listing
    }

    /// Reads a file's bytes through file coordination, inside the folder's security scope.
    static func read(_ file: FolderFile, in folder: URL) throws -> Data {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: file.url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url, options: .mappedIfSafe) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Reads a file by its path inside one of your folders, for showing a source crop later. Documents read
    /// before folders had identifiers (`folderID` empty) are looked up in every folder.
    static func read(relativePath: String, folderID: String) throws -> Data {
        let candidates = folders().filter { folderID.isEmpty || $0.id.uuidString == folderID }
        guard !candidates.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var lastError: Error = CocoaError(.fileNoSuchFile)
        for folder in candidates {
            let url = folder.url.appending(path: relativePath)
            do {
                return try read(FolderFile(url: url, name: url.lastPathComponent, relativePath: relativePath, folderID: folder.id), in: folder.url)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
