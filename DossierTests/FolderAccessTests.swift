import Foundation
import Testing
@testable import Dossier

/// Runs serially: the tests share `FolderAccess.store`.
@Suite(.serialized)
struct FolderAccessTests {
    let suiteName = "FolderAccessTests"

    func withScratchStore(_ body: (URL) throws -> Void) throws {
        let store = try #require(UserDefaults(suiteName: suiteName))
        store.removePersistentDomain(forName: suiteName)
        let previous = FolderAccess.store
        FolderAccess.store = store
        defer {
            FolderAccess.store = previous
            store.removePersistentDomain(forName: suiteName)
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func makeFolder(_ name: String, in root: URL, files: [String] = []) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try Data("%PDF-1.4".utf8).write(to: url.appending(path: file)) }
        return url
    }

    @Test func addsListsAndRemovesSeveralFolders() throws {
        try withScratchStore { root in
            #expect(!FolderAccess.hasFolder)
            let personal = try FolderAccess.add(makeFolder("Personal", in: root))
            let immigration = try FolderAccess.add(makeFolder("Immigration", in: root))
            #expect(FolderAccess.folders().map(\.name) == ["Personal", "Immigration"])

            FolderAccess.remove(personal.id)
            #expect(FolderAccess.folders().map(\.id) == [immigration.id])
            FolderAccess.remove(immigration.id)
            #expect(!FolderAccess.hasFolder)
        }
    }

    @Test func addingTheSameFolderTwiceKeepsOneEntry() throws {
        try withScratchStore { root in
            let url = try makeFolder("Personal", in: root)
            let first = try FolderAccess.add(url)
            let second = try FolderAccess.add(url)
            #expect(first.id == second.id)
            #expect(FolderAccess.folders().count == 1)
        }
    }

    @Test func migratesTheSingleFolderOfEarlierVersions() throws {
        try withScratchStore { root in
            let url = try makeFolder("Personal", in: root)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            FolderAccess.store.set(bookmark, forKey: "documentsFolderBookmark")
            #expect(FolderAccess.folders().map(\.name) == ["Personal"])
            #expect(FolderAccess.store.data(forKey: "documentsFolderBookmark") == nil)
        }
    }

    @Test func listsFilesWithTheirFolderAndRelativePath() throws {
        try withScratchStore { root in
            let url = try makeFolder("Personal", in: root, files: ["Passport.pdf", "notes.txt"])
            _ = try makeFolder("Personal/Leases", in: root, files: ["Lease 2023.pdf"])
            let folder = try FolderAccess.add(url)
            let listing = try FolderAccess.list(folder)
            #expect(Set(listing.files.map(\.relativePath)) == ["Passport.pdf", "Leases/Lease 2023.pdf"])
            #expect(listing.files.allSatisfy { $0.folderID == folder.id })
            let data = try FolderAccess.read(relativePath: "Leases/Lease 2023.pdf", folderID: folder.id.uuidString)
            #expect(data == Data("%PDF-1.4".utf8))
        }
    }
}
