import Foundation
import Testing
import UIKit
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
            #expect(listing.files.allSatisfy { $0.folderID == folder.id && $0.isDownloaded && $0.size == 8 && $0.modified != nil })
            #expect(listing.unsupported == ["notes.txt"])
            let data = try FolderAccess.read(relativePath: "Leases/Lease 2023.pdf", folderID: folder.id.uuidString)
            #expect(data == Data("%PDF-1.4".utf8))
        }
    }
}

struct ImportPlanTests {
    let folderID = UUID()

    func file(downloaded: Bool = true, size: Int = 100, modified: Date = Date(timeIntervalSince1970: 1_000), error: String? = nil) -> FolderAccess.FolderFile {
        FolderAccess.FolderFile(
            url: URL(filePath: "/tmp/Passport.pdf"), name: "Passport.pdf", relativePath: "IDs/Passport.pdf", folderID: folderID,
            isDownloaded: downloaded, size: size, modified: modified, downloadError: error
        )
    }

    var known: [String: KnownFile] {
        [ImportPlan.key(folderID: folderID.uuidString, relativePath: "IDs/Passport.pdf"): KnownFile(size: 100, modified: Date(timeIntervalSince1970: 1_000))]
    }

    @Test func skipsAFileAlreadyReadEvenIfICloudRemovedTheLocalCopy() {
        #expect(ImportPlan.decide(file(downloaded: false), known: known) == .skip)
        #expect(ImportPlan.decide(file(), known: known) == .skip)
    }

    @Test func rereadsAChangedFile() {
        #expect(ImportPlan.decide(file(size: 120), known: known) == .read)
        #expect(ImportPlan.decide(file(downloaded: false, modified: Date(timeIntervalSince1970: 5_000)), known: known) == .download)
    }

    @Test func downloadsNewCloudFilesAndReportsFailures() {
        #expect(ImportPlan.decide(file(downloaded: false), known: [:]) == .download)
        #expect(ImportPlan.decide(file(downloaded: false, error: "Not enough storage"), known: [:]) == .downloadFailed("Not enough storage"))
        #expect(ImportPlan.decide(file(), known: [:]) == .read)
    }

    @Test func readsTextFromEveryPageButKeepsImagesForTheFirstSix() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...9 {
                context.beginPage()
                ("Page \(page) of the lease" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
            }
        }
        let pages = try await PageReader.read(data, fileName: "Lease.pdf")
        #expect(pages.count == 9)
        #expect(pages.filter { $0.image != nil }.count == PageReader.maxImagePages)
        #expect(pages[8].lines.joined(separator: " ").contains("Page 9"))
    }
}
