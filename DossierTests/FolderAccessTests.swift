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

    @discardableResult
    func makeFolder(_ name: String, in root: URL, files: [String] = []) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try Data("%PDF-1.4".utf8).write(to: url.appending(path: file)) }
        return url
    }

    @Test func listsPDFsAndPhotosInAFolderAndItsSubfolders() throws {
        try withScratchStore { root in
            let url = try makeFolder("Personal", in: root, files: ["Passport.pdf", "notes.txt", ".DS_Store"])
            try makeFolder("Personal/Leases", in: root, files: ["Lease 2023.pdf"])
            let listing = try FolderAccess.list(url)
            #expect(listing.files.map(\.relativePath) == ["Leases/Lease 2023.pdf", "Passport.pdf"])
            let allDownloaded = listing.files.allSatisfy(\.isDownloaded)
            #expect(allDownloaded)
            #expect(listing.unsupported == ["notes.txt"])
        }
    }

    @Test func bookmarksAFileSoItCanBeReadAgain() throws {
        try withScratchStore { root in
            let folder = try makeFolder("Personal", in: root, files: ["Passport.pdf"])
            let file = folder.appending(path: "Passport.pdf")
            let bookmark = try FileAccess.bookmark(for: file, within: folder)
            let url = try #require(FileAccess.resolve(bookmark)?.url)
            let data = try FileAccess.read(url)
            #expect(data == Data("%PDF-1.4".utf8))
            let info = try #require(FileAccess.info(for: url))
            #expect(info.isDownloaded && info.size == 8 && info.modified != nil)
            #expect(FileAccess.isReadable(file))
            #expect(!FileAccess.isReadable(folder.appending(path: "notes.txt")))
        }
    }

    @Test func readsTheFoldersOfEarlierVersionsOnceForMigration() throws {
        try withScratchStore { root in
            let url = try makeFolder("Personal", in: root)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            FolderAccess.store.set(bookmark, forKey: "documentsFolderBookmark")
            #expect(FolderAccess.hasLegacyFolders)
            #expect(FolderAccess.legacyFolders().map(\.url.lastPathComponent) == ["Personal"])
            FolderAccess.forgetLegacyFolders()
            #expect(!FolderAccess.hasLegacyFolders)
        }
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

struct ReconcilerTests {
    func candidate(_ value: String, from source: String, priority: Int = 0, checked: Bool = false, certain: Bool = true, key: ProfileKey) -> ProfileCandidate {
        ProfileCandidate(
            id: source, matchKey: Reconciler.normalize(value, for: key), value: value, sourceTitle: source,
            priority: priority, isChecked: checked, isCertain: certain
        )
    }

    @Test func acceptsNamesThatAgreeIncludingInitials() {
        let key = ProfileKey.givenNames
        let entry = Reconciler.reconcile(key, candidates: [
            candidate("Anna Maria", from: "Passport", key: key),
            candidate("ANNA M.", from: "Driver’s licence", priority: 4, key: key),
            candidate("Anna", from: "I-94", priority: 6, key: key),
        ])
        #expect(entry.status == .agreed(count: 3))
        #expect(entry.chosen?.value == "Anna Maria", "the most complete spelling from the most authoritative document")
    }

    @Test func flagsDocumentsThatDisagree() {
        let key = ProfileKey.dateOfBirth
        let entry = Reconciler.reconcile(key, candidates: [
            candidate("1990-08-12", from: "Passport", checked: true, key: key),
            candidate("1990-12-08", from: "Lease application", priority: 3, key: key),
        ])
        #expect(entry.status == .conflict)
        #expect(entry.chosen == nil)
        #expect(entry.groups.first?.first?.sourceTitle == "Passport", "the checked reading is offered first")
    }

    @Test func treatsCountryNameAndDemonymAsTheSame() {
        let key = ProfileKey.nationality
        let entry = Reconciler.reconcile(key, candidates: [
            candidate("UTOPIAN", from: "Passport", key: key),
            candidate("Utopia", from: "Visa", priority: 1, key: key),
        ])
        #expect(entry.status == .agreed(count: 2))
    }

    @Test func leavesDoubtfulReadingsOutOfTheCompiledValue() {
        let key = ProfileKey.surname
        let entry = Reconciler.reconcile(key, candidates: [
            candidate("Eriksson", from: "Passport", key: key),
            candidate("Erikson", from: "Photo of a notice", priority: 7, certain: false, key: key),
        ])
        #expect(entry.status == .single)
        #expect(entry.chosen?.value == "Eriksson")
        #expect(Reconciler.reconcile(key, candidates: [candidate("Erikson", from: "Photo", certain: false, key: key)]).status == .uncertain)
    }

    @Test func comparesANumbersWithoutFormatting() {
        #expect(Reconciler.normalize("A-012-345-678", for: .alienNumber) == Reconciler.normalize("12345678", for: .alienNumber))
        #expect(Reconciler.namesCompatible("A MARIA", "ANNA MARIA"))
        #expect(!Reconciler.namesCompatible("MARIA", "ANNA MARIA"))
    }
}
