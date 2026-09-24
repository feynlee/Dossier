import Foundation
import UniformTypeIdentifiers

/// Folder paths for display, and the folders earlier versions kept. Dossier doesn't keep folders: it keeps
/// the individual files you add (see `FileAccess`).
nonisolated enum FolderAccess {
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
