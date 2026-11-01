import FileProvider

/// Lists a folder's contents, or for the working set everything in the library. Changes aren't tracked one
/// by one: when the library has changed, Files is told its anchor expired and lists everything again.
final class LibraryEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let index = LibraryIndex.load()
        let entries = index?.entries ?? []
        if container == .workingSet {
            let folders = (index?.folders ?? []).map { LibraryItem(folder: $0) }
            observer.didEnumerate(folders + entries.map { LibraryItem($0) })
        } else if case .folder(let path)? = LibraryItem.place(of: container) {
            let contents = index?.contents(of: path) ?? (folders: [], entries: [])
            observer.didEnumerate(contents.folders.map { LibraryItem(folder: path + [$0]) } + contents.entries.map { LibraryItem($0) })
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if anchor == Self.currentAnchor() {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.currentAnchor())
    }

    private static func currentAnchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(LibraryIndex.load()?.updated.timeIntervalSince1970 ?? 0)".utf8))
    }
}
