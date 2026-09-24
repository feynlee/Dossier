import Foundation
import UniformTypeIdentifiers

/// Browsing a folder you picked, so you can choose which of its files to add. Dossier doesn't keep folders:
/// it keeps the individual files you add (see `FileAccess`).
nonisolated enum FolderAccess {
    /// A PDF or image inside a picked folder.
    struct FolderFile: Identifiable, Hashable, Sendable {
        var id: URL { url }
        var url: URL
        var name: String
        /// Path inside the folder, such as "Leases/Lease 2023.pdf".
        var relativePath: String
        /// False for a file that is in iCloud but not on this device yet.
        var isDownloaded = true
    }

    struct Listing: Sendable {
        /// PDFs and images, downloaded or not.
        var files: [FolderFile]
        /// Other files in the folder, which Dossier doesn't read (Word documents, spreadsheets…).
        var unsupported: [String]
    }

    /// Lists the PDFs and images in a folder and its subfolders, including iCloud files that aren't on this
    /// device yet. Nothing is downloaded.
    static func list(_ folder: URL) throws -> Listing {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var listing = Listing(files: [], unsupported: [])
        var enumerationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .withoutChanges, error: &coordinationError) { url in
            let keys: [URLResourceKey] = [.contentTypeKey, .isDirectoryKey, .ubiquitousItemDownloadingStatusKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
                return
            }
            let root = url.standardizedFileURL.path
            for case let fileURL as URL in enumerator {
                do {
                    let values = try fileURL.resourceValues(forKeys: Set(keys))
                    if values.isDirectory == true { continue }

                    // Older iCloud placeholders are hidden files named ".Passport.pdf.icloud".
                    var name = fileURL.lastPathComponent
                    let isLegacyPlaceholder = fileURL.pathExtension == "icloud" && name.hasPrefix(".")
                    if isLegacyPlaceholder { name = String(name.dropFirst().dropLast(".icloud".count)) }
                    if name.hasPrefix(".") { continue }

                    let type = isLegacyPlaceholder ? UTType(filenameExtension: (name as NSString).pathExtension) : values.contentType
                    guard let type, FileAccess.readableTypes.contains(where: { type.conforms(to: $0) }) else {
                        listing.unsupported.append(name)
                        continue
                    }
                    let path = fileURL.deletingLastPathComponent().appending(path: name).standardizedFileURL.path
                    let relative = path.hasPrefix(root)
                        ? String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        : name
                    listing.files.append(FolderFile(
                        url: fileURL,
                        name: name,
                        relativePath: relative,
                        isDownloaded: !isLegacyPlaceholder && values.ubiquitousItemDownloadingStatus != .notDownloaded
                    ))
                } catch {
                    enumerationError = error
                }
            }
        }
        if let error = coordinationError ?? (listing.files.isEmpty ? enumerationError as NSError? : nil) { throw error }
        listing.files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return listing
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

    // MARK: Earlier versions

    /// Where earlier versions kept the folders you added. Read once to give their documents their own bookmark.
    nonisolated(unsafe) static var store = UserDefaults.standard
    private static let legacyFoldersKey = "documentsFolders"
    private static let legacyBookmarkKey = "documentsFolderBookmark"

    private struct LegacyFolder: Codable {
        var id: UUID
        var bookmark: Data
    }

    /// Folders saved by earlier versions, as (identifier, url).
    static func legacyFolders() -> [(id: String, url: URL)] {
        var entries: [LegacyFolder] = []
        if let data = store.data(forKey: legacyFoldersKey), let saved = try? JSONDecoder().decode([LegacyFolder].self, from: data) {
            entries = saved
        } else if let bookmark = store.data(forKey: legacyBookmarkKey) {
            entries = [LegacyFolder(id: UUID(), bookmark: bookmark)]
        }
        return entries.compactMap { entry in
            FileAccess.resolve(entry.bookmark).map { (entry.id.uuidString, $0.url) }
        }
    }

    static var hasLegacyFolders: Bool {
        store.data(forKey: legacyFoldersKey) != nil || store.data(forKey: legacyBookmarkKey) != nil
    }

    static func forgetLegacyFolders() {
        store.removeObject(forKey: legacyFoldersKey)
        store.removeObject(forKey: legacyBookmarkKey)
    }
}
