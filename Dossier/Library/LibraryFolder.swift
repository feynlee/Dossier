import Foundation
import os

/// iCloud Drive › Dossier: a file for every document in the vault, sorted into the library's folders and
/// named once Dossier has read them. Scans and files shared to Dossier are kept here from the start; a file
/// you added from one of your own folders is copied in, and yours stays where it is.
nonisolated enum LibraryFolder {
    static let containerIdentifier = "iCloud.liziyue.Dossier"
    private static let logger = Logger(subsystem: "liziyue.Dossier", category: "Library")

    /// The folder, created if needed; nil when iCloud Drive is off or not signed in. Can block while iCloud
    /// sets up the container, so call it off the main thread.
    static func root() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else { return nil }
        let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    static func findRoot() async -> URL? {
        await Task.detached(priority: .utility) { root() }.value
    }

    /// Whether Dossier keeps this file itself, so it may move and rename it.
    static func contains(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(rootPath + "/")
    }

    /// Where a document's file belongs: root › [person ›] category › folder › name.ext.
    static func destination(for placement: LibraryPlacement, showingPerson: Bool, fileExtension: String, root: URL) -> URL {
        let folder = placement.path(showingPerson: showingPerson).reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
        let ext = fileExtension.isEmpty ? "pdf" : fileExtension
        return folder.appending(path: "\(placement.name).\(ext)")
    }

    /// Moves a file Dossier keeps to where it belongs, through file coordination. Returns the new location,
    /// or nil if it couldn't be moved (it stays where it was). A file already at the destination with other
    /// contents is never replaced: the moved file gets a number instead.
    static func move(_ file: URL, to destination: URL) -> URL? {
        guard file.standardizedFileURL != destination.standardizedFileURL else { return file }
        let manager = FileManager.default
        var target = destination
        var number = 2
        while manager.fileExists(atPath: target.path), target.standardizedFileURL != file.standardizedFileURL {
            let base = destination.deletingPathExtension().lastPathComponent
            target = destination.deletingLastPathComponent().appending(path: "\(base) (\(number)).\(destination.pathExtension)")
            number += 1
        }
        if target.standardizedFileURL == file.standardizedFileURL { return file }
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't make a library folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        var coordinationError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: file, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinationError) { from, to in
            do {
                try manager.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError {
            logger.error("Couldn't move a library file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        removeEmptyFolders(above: file.deletingLastPathComponent(), stoppingAt: destination)
        return target
    }

    /// Writes a copy of a file into the library. Returns where it went, or nil if it couldn't be written. A
    /// file already at the destination is never replaced: when it holds the same bytes it is the copy (from
    /// an earlier pass), otherwise the copy gets a number.
    static func copy(_ data: Data, to destination: URL, modified: Date?) -> URL? {
        let manager = FileManager.default
        var target = destination
        var number = 2
        while manager.fileExists(atPath: target.path) {
            if (try? Data(contentsOf: target, options: .mappedIfSafe)) == data { return target }
            let base = destination.deletingPathExtension().lastPathComponent
            target = destination.deletingLastPathComponent().appending(path: "\(base) (\(number)).\(destination.pathExtension)")
            number += 1
        }
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't make a library folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .atomic)
                if let modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError {
            logger.error("Couldn't copy a file into the library: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return target
    }

    /// Removes every folder in the library that holds no files, deepest first: a person folder left behind
    /// when the library went from several people to one (seen on a real vault: an empty Ziyue › Identity ›
    /// Passports), or a folder a layout change emptied. Folders holding only hidden files count as empty.
    static func removeEmptyFolders(in root: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var folders: [URL] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            folders.append(url)
        }
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            guard let contents = try? manager.contentsOfDirectory(atPath: folder.path), contents.allSatisfy({ $0.hasPrefix(".") && !$0.hasSuffix(".icloud") }) else { continue }
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder, options: .forDeleting, error: &coordinationError) { url in
                try? manager.removeItem(at: url)
            }
        }
    }

    /// Cleans up folders a move left empty, up to the library's top.
    private static func removeEmptyFolders(above folder: URL, stoppingAt destination: URL) {
        guard let root = root() else { return }
        var current = folder
        while contains(current.appending(path: "x"), root: root), current.standardizedFileURL != root.standardizedFileURL,
              !destination.standardizedFileURL.path.hasPrefix(current.standardizedFileURL.path + "/"),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
              contents.allSatisfy({ $0.hasPrefix(".") }) {
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}
