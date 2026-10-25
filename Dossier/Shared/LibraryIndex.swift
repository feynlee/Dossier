import Foundation

/// The library as the Dossier location in Files shows it: every placed document's folders and name, and a
/// copy of its file. Dossier writes it into the app group it shares with its Files extension, which only
/// reads it. Holds no facts, only what Files shows anyway.
nonisolated struct LibraryIndex: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Hashable, Sendable {
        /// The document's content hash.
        var id: String
        /// Folder names from the top: Person › Category › Folder, or Category › Folder for one person.
        var path: [String]
        /// The file name shown in Files, with its extension.
        var name: String
        var size: Int64
        var added: Date
        var modified: Date

        var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    }

    var entries: [Entry]
    /// Changes whenever the entries do, so Files knows to look again.
    var updated: Date

    static let appGroup = "group.liziyue.Dossier"
    static let domainIdentifier = "liziyue.Dossier.library"

    // MARK: Storage

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var indexURL: URL? { container?.appending(path: "Library/library-index.json") }

    /// Copies of the files. In Caches, so the system may clear them when space runs low; Dossier copies
    /// them again the next time it opens.
    static var filesDirectory: URL? { container?.appending(path: "Library/Caches/Library Files", directoryHint: .isDirectory) }

    static func fileURL(for entry: Entry) -> URL? {
        filesDirectory?.appending(path: entry.fileExtension.isEmpty ? entry.id : "\(entry.id).\(entry.fileExtension)")
    }

    static func load() -> LibraryIndex? {
        guard let url = indexURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    func save() throws {
        guard let url = Self.indexURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
    }

    // MARK: Folders

    /// Every folder that holds a document, directly or further down, by its path.
    var folders: Set<[String]> {
        var result: Set<[String]> = []
        for entry in entries {
            for depth in stride(from: 1, through: entry.path.count, by: 1) { result.insert(Array(entry.path.prefix(depth))) }
        }
        return result
    }

    /// What a folder holds: its subfolders by name, and its documents.
    func contents(of path: [String]) -> (folders: [String], entries: [Entry]) {
        let subfolders = Set(entries.compactMap { $0.path.count > path.count && Array($0.path.prefix(path.count)) == path ? $0.path[path.count] : nil })
        let files = entries.filter { $0.path == path }
        return (subfolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    // MARK: Identifiers in Files

    /// "folder:Mei/Immigration/EAD cards" for a folder, "doc:<hash>" for a document. The top is "".
    static func identifier(forFolder path: [String]) -> String { path.isEmpty ? "" : "folder:" + path.joined(separator: "/") }
    static func identifier(forEntry id: String) -> String { "doc:" + id }

    enum Item: Equatable {
        case folder([String])
        case entry(String)
    }

    /// Folder names never hold "/", because the library cleans it out of every name.
    static func item(for identifier: String) -> Item? {
        if identifier.isEmpty { return .folder([]) }
        if identifier.hasPrefix("folder:") { return .folder(identifier.dropFirst("folder:".count).split(separator: "/").map(String.init)) }
        if identifier.hasPrefix("doc:") { return .entry(String(identifier.dropFirst("doc:".count))) }
        return nil
    }
}
