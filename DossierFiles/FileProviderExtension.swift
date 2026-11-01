import FileProvider
import os

/// The Dossier location in Files: your library, organized by person, category and kind, read-only. Dossier
/// writes the library index and a copy of each file to the app group; this only reads them.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: "liziyue.Dossier.Files", category: "Files")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if let item = LibraryItem.make(identifier, in: LibraryIndex.load()) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard let index = LibraryIndex.load(), case .entry(let id)? = LibraryItem.place(of: itemIdentifier),
              let entry = index.entries.first(where: { $0.id == id }), let source = LibraryIndex.fileURL(for: entry)
        else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        do {
            guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
            let copy = try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            completionHandler(copy, LibraryItem(entry), nil)
        } catch {
            // The copy was cleared to free space. Dossier makes it again the next time it opens.
            logger.error("Couldn't serve a file: \(String(describing: error), privacy: .public)")
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
        }
        return Progress()
    }

    // The library is read-only in Files: you rename and move documents in Dossier.

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(CocoaError(.featureUnsupported))
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier == .workingSet || LibraryItem.place(of: containerItemIdentifier) != nil else {
            throw NSFileProviderError(.noSuchItem)
        }
        return LibraryEnumerator(container: containerItemIdentifier)
    }
}
