import Foundation
import SwiftData
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

struct DocumentIdentityTests {
    func keys(_ kind: DocumentKind, _ values: [FactKey: String], travel: [String] = []) -> DocumentKeys {
        DocumentIdentity.plainKeys(kind: kind, values: values, travel: travel)
    }

    let passport: [FactKey: String] = [
        .surname: "ERIKSSON", .givenNames: "ANNA MARIA", .dateOfBirth: "1990-08-12",
        .documentNumber: "PX7204821", .issueDate: "2019-03-15", .expiryDate: "2029-03-14",
    ]

    @Test func twoScansOfTheSamePassportAreDuplicates() {
        var rescan = passport
        rescan[.documentNumber] = "px 720 4821"
        #expect(DocumentIdentity.match(keys(.passport, rescan), against: keys(.passport, passport)) == .duplicate)
    }

    @Test func aCorrectedReadingOfTheSameDocumentIsAnUpdate() {
        var corrected = passport
        corrected[.givenNames] = "ANNA MARIE"
        #expect(DocumentIdentity.match(keys(.passport, corrected), against: keys(.passport, passport)) == .update)
    }

    @Test func aRenewedLicenceWithTheSameNumberIsASeparateDocument() {
        let old: [FactKey: String] = [.documentNumber: "D1234567", .issueDate: "2023-01-30", .expiryDate: "2027-01-30", .address: "88 Pine Ave"]
        var renewed = old
        renewed[.issueDate] = "2027-01-15"
        renewed[.expiryDate] = "2031-01-30"
        #expect(DocumentIdentity.match(keys(.driversLicense, renewed), against: keys(.driversLicense, old)) == .newVersion)
    }

    @Test func differentDocumentsDontMatch() {
        var other = passport
        other[.documentNumber] = "PX9999999"
        #expect(DocumentIdentity.match(keys(.passport, other), against: keys(.passport, passport)) == .none)
        #expect(DocumentIdentity.match(keys(.passport, [:]), against: keys(.passport, [:])) == .none, "no number, no match")
    }

    @Test func aNewerI94HistoryUpdatesTheOldOne() {
        let old = keys(.i94, [.surname: "ERIKSSON"], travel: ["2021-06-12 departure SEA"])
        let newer = keys(.i94, [.surname: "ERIKSSON"], travel: ["2021-06-12 departure SEA", "2021-07-03 arrival SEA"])
        #expect(DocumentIdentity.match(newer, against: old) == .update)
        #expect(DocumentIdentity.match(old, against: old) == .duplicate)
    }

    @Test func leasesMatchByAddressAndStart() {
        let lease: [FactKey: String] = [.address: "88 Pine Ave, Portland", .leaseStartDate: "2023-01-01", .leaseEndDate: "2027-12-31"]
        var extended = lease
        extended[.leaseEndDate] = "2028-12-31"
        var next = lease
        next[.leaseStartDate] = "2028-01-01"
        #expect(DocumentIdentity.match(keys(.lease, extended), against: keys(.lease, lease)) == .update)
        #expect(DocumentIdentity.match(keys(.lease, next), against: keys(.lease, lease)) == .none)
    }

    @Test func noticesARemovedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Passport.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let bookmark = try FileAccess.bookmark(for: file)
        #expect(FileAccess.resolve(bookmark).map { FileAccess.exists($0.url) } == true)
        try FileManager.default.removeItem(at: file)
        #expect(FileAccess.resolve(bookmark).map { FileAccess.exists($0.url) } != true)
    }

    @Test func followsAMovedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appending(path: "IDs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Passport.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let bookmark = try FileAccess.bookmark(for: file)
        let moved = folder.appending(path: "IDs/Passport renamed.pdf")
        try FileManager.default.moveItem(at: file, to: moved)
        let resolved = try #require(FileAccess.resolve(bookmark))
        #expect(resolved.url.lastPathComponent == "Passport renamed.pdf")
        #expect(FileAccess.exists(resolved.url))
    }
}

@MainActor
struct RemovingTests {
    func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SourceDocument.self, Fact.self, TravelEvent.self, ProfileOverride.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func document(_ hash: String, state: DocumentState = .ready, in context: ModelContext) -> SourceDocument {
        let document = SourceDocument(contentHash: hash, fileName: "\(hash).pdf", kind: .passport, title: hash, engine: .privateCloudCompute, pageCount: 1)
        document.state = state
        context.insert(document)
        return document
    }

    @Test func removingTheOldVersionKeepsTheUpdateAsItsOwnDocument() throws {
        let context = try context()
        let old = document("old", in: context)
        let update = document("new", state: .awaitingDecision, in: context)
        update.decisionRaw = "update"
        update.relatedHash = "old"
        let other = document("other", in: context)
        try context.save()

        ImportCoordinator().remove([old], context: context, preferPrivateCloud: true)

        let left = try context.fetch(FetchDescriptor<SourceDocument>()).map(\.contentHash).sorted()
        #expect(left == ["new", "other"])
        #expect(update.state == .ready)
        #expect(update.relatedHash == nil)
        #expect(other.state == .ready)
    }

    @Test func removingEverythingAlsoRemovesEdits() throws {
        let context = try context()
        _ = document("a", in: context)
        _ = document("b", in: context)
        context.insert(ProfileOverride(key: "surname", sealedValue: Data([1]), isSensitive: false))
        try context.save()

        // Not `removeAll`, which also destroys the app's Keychain keys.
        ImportCoordinator.deleteAllRecords(context: context)

        #expect(try context.fetchCount(FetchDescriptor<SourceDocument>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ProfileOverride>()) == 0)
    }
}

@MainActor
struct SharedConfirmationTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: SourceDocument.self, Fact.self, TravelEvent.self, ProfileOverride.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    @discardableResult
    func fact(_ key: FactKey, _ value: String, on title: String, kind: DocumentKind = .passport, status: FactStatus = .needsReview) throws -> Fact {
        let document = SourceDocument(contentHash: title, fileName: "\(title).pdf", kind: kind, title: title, engine: .privateCloudCompute, pageCount: 1)
        document.state = .ready
        context.insert(document)
        let fact = Fact(key: key, sealedValue: try Sealer.shared.seal(value, sensitive: false), sealedHint: nil, status: status, check: .model, page: 1)
        fact.document = document
        context.insert(fact)
        try context.save()
        return fact
    }

    @Test func confirmingANameConfirmsTheSameNameElsewhere() throws {
        let passport = try fact(.givenNames, "ANNA MARIA", on: "Passport")
        let card = try fact(.givenNames, "Anna Maria", on: "Green card", kind: .greenCard)
        let other = try fact(.givenNames, "ANNA", on: "Lease", kind: .lease)

        let shared = FactEditor.confirm(passport, value: nil, context: context)

        #expect(shared == ["Green card"])
        #expect(card.status == .verified && card.check == .userConfirmed)
        #expect(other.status == .needsReview)
    }

    @Test func documentSpecificFieldsAreNotShared() throws {
        let first = try fact(.expiryDate, "2029-03-14", on: "Passport")
        let second = try fact(.expiryDate, "2029-03-14", on: "Visa", kind: .visa)

        FactEditor.confirm(first, value: nil, context: context)

        #expect(second.status == .needsReview)
    }

    @Test func aCorrectionIsSharedToo() throws {
        let passport = try fact(.placeOfBirth, "STOCKHOLN", on: "Passport")
        let card = try fact(.placeOfBirth, "Stockholm", on: "Green card", kind: .greenCard)

        FactEditor.confirm(passport, value: "STOCKHOLM", context: context)

        #expect(card.status == .verified)
    }

    @Test func aNewDocumentUsesWhatYouAlreadyConfirmed() throws {
        let passport = try fact(.dateOfBirth, "1990-08-12", on: "Passport")
        FactEditor.confirm(passport, value: nil, context: context)
        let licence = try fact(.dateOfBirth, "1990-08-12", on: "Licence", kind: .driversLicense)

        SharedConfirmation.apply(to: try #require(licence.document), context: context)

        #expect(licence.status == .verified)
    }
}
