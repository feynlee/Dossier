import Foundation

/// What the importer does with one file in a folder.
nonisolated enum ImportDecision: Equatable, Sendable {
    /// Already read and unchanged since: skip it, even if iCloud removed the local copy.
    case skip
    /// In iCloud but not on this device: ask iCloud for it and read it once it arrives.
    case download
    /// iCloud tried to download it and failed.
    case downloadFailed(String)
    /// On the device and not read yet (or changed): read it.
    case read
}

/// What Dossier remembers about a file it already read, to recognise it without downloading it again.
nonisolated struct KnownFile: Sendable {
    var size: Int?
    var modified: Date?
}

nonisolated enum ImportPlan {
    static func key(folderID: String, relativePath: String) -> String {
        "\(folderID)/\(relativePath)"
    }

    static func decide(_ file: FolderAccess.FolderFile, known: [String: KnownFile]) -> ImportDecision {
        if let previous = known[key(folderID: file.folderID.uuidString, relativePath: file.relativePath)],
           let size = previous.size, size == file.size,
           let before = previous.modified, let now = file.modified, abs(before.timeIntervalSince(now)) < 1 {
            return .skip
        }
        if !file.isDownloaded {
            return file.downloadError.map(ImportDecision.downloadFailed) ?? .download
        }
        return .read
    }
}
