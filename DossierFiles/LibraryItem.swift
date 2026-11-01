import FileProvider
import UniformTypeIdentifiers

/// A folder or document in the Dossier location.
final class LibraryItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?

    init(_ entry: LibraryIndex.Entry) {
        itemIdentifier = NSFileProviderItemIdentifier(LibraryIndex.identifier(forEntry: entry.id))
        parentItemIdentifier = Self.identifier(forFolder: entry.path)
        filename = entry.name
        contentType = UTType(filenameExtension: entry.fileExtension) ?? .data
        capabilities = [.allowsReading]
        itemVersion = NSFileProviderItemVersion(
            contentVersion: Data("\(entry.id) \(entry.modified.timeIntervalSince1970)".utf8),
            metadataVersion: Data((entry.path + [entry.name]).joined(separator: "/").utf8)
        )
        documentSize = NSNumber(value: entry.size)
        creationDate = entry.added
        contentModificationDate = entry.modified
    }

    init(folder path: [String]) {
        itemIdentifier = Self.identifier(forFolder: path)
        parentItemIdentifier = path.isEmpty ? .rootContainer : Self.identifier(forFolder: Array(path.dropLast()))
        filename = path.last ?? "Dossier"
        contentType = .folder
        capabilities = [.allowsReading, .allowsContentEnumerating]
        itemVersion = NSFileProviderItemVersion(contentVersion: Data("folder".utf8), metadataVersion: Data(path.joined(separator: "/").utf8))
        documentSize = nil
        creationDate = nil
        contentModificationDate = nil
    }

    static func identifier(forFolder path: [String]) -> NSFileProviderItemIdentifier {
        path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(LibraryIndex.identifier(forFolder: path))
    }

    static func place(of identifier: NSFileProviderItemIdentifier) -> LibraryIndex.Item? {
        identifier == .rootContainer ? .folder([]) : LibraryIndex.item(for: identifier.rawValue)
    }

    /// The item for an identifier, if the library still has it.
    static func make(_ identifier: NSFileProviderItemIdentifier, in index: LibraryIndex?) -> LibraryItem? {
        switch place(of: identifier) {
        case .folder(let path):
            guard path.isEmpty || index?.folders.contains(path) == true else { return nil }
            return LibraryItem(folder: path)
        case .entry(let id):
            return index?.entries.first { $0.id == id }.map { LibraryItem($0) }
        case nil:
            return nil
        }
    }
}
