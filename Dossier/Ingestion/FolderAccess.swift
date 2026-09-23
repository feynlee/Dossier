import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The user's documents folder, remembered as a bookmark so Dossier can read it again on later launches.
/// Files are read in place and never copied.
nonisolated struct FolderAccess: Sendable {
    private static let bookmarkKey = "documentsFolderBookmark"

    static let readableTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff]

    struct FolderFile: Sendable, Hashable {
        var url: URL
        var name: String
    }

    struct Listing: Sendable {
        var files: [FolderFile]
        /// Files that are in iCloud but not downloaded yet. Dossier asks iCloud to download them and reads
        /// them on the next scan.
        var waitingForDownload: Int
    }

    // MARK: Bookmark

    static func save(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale { try? save(url) }
        return url
    }

    static var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// "iCloud Drive › Documents › Personal"-style path for display.
    static func displayPath(for url: URL) -> String {
        let components = url.pathComponents
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + components[(index + 1)...]).joined(separator: " › ")
        }
        return components.suffix(3).joined(separator: " › ")
    }

    // MARK: Listing

    /// Lists readable files in the folder and its subfolders, and starts downloads for iCloud placeholders.
    static func list(_ folder: URL) throws -> Listing {
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
                    listing.files.append(FolderFile(url: fileURL, name: fileURL.lastPathComponent))
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

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
