import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Access to the individual files you add to Dossier. Each file is remembered as a bookmark, so it can be read
/// again (to re-read it after a change, or to show it next to its facts) without being copied.
nonisolated enum FileAccess {
    static let readableTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff]

    /// What iCloud and the file system report about a file, without downloading it.
    struct Info: Equatable, Sendable {
        var isDownloaded: Bool
        var size: Int?
        var modified: Date?
        var downloadError: String?
    }

    static func isReadable(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    // MARK: Bookmarks

    /// Creates a bookmark for a file you picked. Pass the folder when the file came from a folder you picked,
    /// because access to it goes through the folder's security scope.
    static func bookmark(for url: URL, within folder: URL? = nil) throws -> Data {
        let scope = folder ?? url
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark. `refreshed` is set when the bookmark was stale and should be saved again.
    static func resolve(_ bookmark: Data) -> (url: URL, refreshed: Data?)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        return (url, isStale ? try? Self.bookmark(for: url) : nil)
    }

    // MARK: Reading

    static func info(for url: URL) -> Info? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return Info(
            isDownloaded: values.ubiquitousItemDownloadingStatus != .notDownloaded,
            size: values.fileSize,
            modified: values.contentModificationDate,
            downloadError: values.ubiquitousItemDownloadingError?.localizedDescription
        )
    }

    /// Whether the file is still there. A file in the Trash counts as removed. An iCloud file that isn't
    /// downloaded yet still exists.
    static func exists(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if url.standardizedFileURL.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Asks iCloud to download a file. The download continues in the system even if Dossier is suspended.
    static func requestDownload(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Reads a file through file coordination, inside its security scope. For an iCloud file that isn't on
    /// the device, coordination downloads it first.
    static func read(_ url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url, options: .mappedIfSafe) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
