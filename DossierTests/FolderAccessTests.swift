import Foundation
import PDFKit
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

struct ScanTests {
    @Test func scanNamesAreSafeAndDontOverwrite() {
        #expect(ScanFolders.fileName(for: "Passport", existing: []) == "Passport.pdf")
        #expect(ScanFolders.fileName(for: "Passport", existing: ["passport.pdf", "passport 2.pdf"]) == "Passport 3.pdf")
        #expect(ScanFolders.fileName(for: "Lease 1/2", existing: []) == "Lease 1 2.pdf")
        #expect(ScanFolders.fileName(for: "  ", existing: []).hasPrefix("Scan "))
    }

    /// A dark photo with a white page in it: the page is found, cut out and flattened, then saved as a PDF.
    @Test func findsThePageInAPhotoAndMakesAPDF() throws {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 250, y: 300, width: 700, height: 950))
        }
        var page = try #require(ScannedPage.make(from: photo, fallback: nil))
        let flat = try #require(page.pageImage)
        // The page, not the whole photo: about 700 x 950.
        #expect(abs(flat.size.width - 700) < 40 && abs(flat.size.height - 950) < 40)

        page.turns = 1
        page.rerender()
        let turned = try #require(page.pageImage)
        #expect(turned.size.width > turned.size.height)

        let pdf = try #require(ScanPDF.make([page, page]))
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        #expect(document.numberOfPages == 2)
    }
}

@MainActor
struct PageEditingTests {
    /// A PDF whose pages have different heights (100, 200, 300 pt), so their order can be checked.
    func makePDF() throws -> URL {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        for height in [100, 200, 300] {
            var box = CGRect(x: 0, y: 0, width: 400, height: height)
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }

    func document(for url: URL) throws -> SourceDocument {
        let document = SourceDocument.pending(fileName: url.lastPathComponent, bookmark: try FileAccess.bookmark(for: url))
        return document
    }

    func heights(_ data: Data) throws -> [Int] {
        let pdf = try #require(PDFDocument(data: data))
        return (0..<pdf.pageCount).map { Int(pdf.page(at: $0)!.bounds(for: .mediaBox).height) }
    }

    @Test func reordersDeletesAndRotatesPages() async throws {
        let url = try makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let draft = PageDraft()
        await draft.load(try document(for: url))
        #expect(draft.isPDF && draft.pages.count == 3 && !draft.hasChanges)

        let ids = draft.pages.map(\.id)
        draft.move(ids[2], before: ids[0])          // 300, 100, 200
        draft.delete([ids[1]])                      // 300, 100
        draft.rotate([ids[0]])
        #expect(draft.hasChanges)
        let data = try #require(draft.pdfData())
        #expect(try heights(data) == [300, 100])
        #expect(PDFDocument(data: data)?.page(at: 1)?.rotation == 90)

        // Saving writes the file in place.
        try FileAccess.write(data, to: url)
        #expect(try heights(Data(contentsOf: url)) == [300, 100])
    }

    @Test func aPhotoBecomesAOnePagePDF() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        try #require(image.jpegData(compressionQuality: 0.8)).write(to: url)
        let draft = PageDraft()
        await draft.load(try document(for: url))
        #expect(!draft.isPDF && draft.pages.count == 1)
    }
}

struct IncomingFileTests {
    @Test func aCopyHandedToDossierIsSavedToICloudFirst() throws {
        let inbox = URL.documentsDirectory.appending(path: "Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let pdf = inbox.appending(path: "Lease.pdf"), notes = inbox.appending(path: "notes.txt")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        try Data("hi".utf8).write(to: notes)
        defer { try? FileManager.default.removeItem(at: inbox) }

        #expect(IncomingFiles.isCopyInDossier(pdf))
        #expect(IncomingFiles.route(for: pdf) == .chooseFolder)
        #expect(IncomingFiles.route(for: notes) == .unsupported)

        // Once handled, Dossier's own copy is deleted.
        let files = IncomingFiles()
        files.receive(pdf)
        files.finish(pdf)
        #expect(files.queue.isEmpty && !FileManager.default.fileExists(atPath: pdf.path))
    }

    @Test func savedCopiesKeepTheirType() {
        #expect(ScanFolders.fileName(for: "Passport", existing: [], extension: "jpg") == "Passport.jpg")
    }
}

struct DetailExtractionTests {
    @Test func instructionsAskForFamilyAndYourOwnList() {
        let text = DocumentExtractor.instructions(for: DetailRequest(findsUsefulDetails: true, requested: ["Height", "Employer"]))
        #expect(text.contains("Family members of the holder"))
        #expect(text.contains("\"Height\", \"Employer\""))
        let none = DocumentExtractor.instructions(for: DetailRequest(findsUsefulDetails: false, requested: []))
        #expect(none.hasSuffix("Leave details empty; put everything in fields and contents."))
    }

    @Test func detailsAreCheckedAgainstThePageText() {
        let pages = [["FATHER ERIK ERIKSSON", "BORN 03 MAR 1961", "HEIGHT 170 CM"]]
        let date = Verifier.verifyDetail("1961-03-03", isConfident: true, page: 1, pages: pages)
        #expect(date?.status == .verified && date?.check == .pageText)
        let height = Verifier.verifyDetail("170 cm", isConfident: true, page: 1, pages: pages)
        #expect(height?.status == .verified)
        // A number that isn't on the page needs a look.
        let phone = Verifier.verifyDetail("555 0100", isConfident: true, page: 1, pages: pages)
        #expect(phone?.status == .needsReview)
        // So does anything the model wasn't sure of.
        #expect(Verifier.verifyDetail("Engineer", isConfident: false, page: 1, pages: pages)?.status == .needsReview)
    }
}

@MainActor
struct ProfileDetailsTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: SourceDocument.self, Fact.self, TravelEvent.self, ProfileOverride.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        context = ModelContext(container)
    }

    func document(_ title: String) -> SourceDocument {
        let document = SourceDocument(contentHash: title, fileName: "\(title).pdf", kind: .other, title: title, engine: .privateCloudCompute, pageCount: 1)
        document.state = .ready
        context.insert(document)
        return document
    }

    func detail(_ label: String, _ value: String, on document: SourceDocument, relation: Relation? = nil, person: String? = nil) throws {
        let fact = Fact(key: .detail, sealedValue: try Sealer.shared.seal(value, sensitive: false), sealedHint: nil, status: .verified, check: .pageText, page: 1)
        fact.label = label
        fact.relationRaw = relation?.rawValue
        fact.sealedPersonName = try person.map { try Sealer.shared.seal($0, sensitive: false) }
        fact.document = document
        context.insert(fact)
    }

    @Test func mergesTheSameDetailAndGroupsFamily() throws {
        let passport = document("Passport"), certificate = document("Birth certificate")
        try detail("Height", "170 cm", on: passport)
        try detail("HEIGHT", "170 cm", on: certificate)
        try detail("Name", "ERIK ERIKSSON", on: certificate, relation: .father, person: "ERIK ERIKSSON")
        try detail("Date of birth", "1961-03-03", on: certificate, relation: .father, person: "Erik Eriksson")
        try detail("Name", "ANNA LIND", on: certificate, relation: .mother, person: "ANNA LIND")
        try context.save()

        let details = ProfileDetails.build(documents: [passport, certificate])
        #expect(details.you.count == 1)
        #expect(details.you[0].sources == ["Birth certificate", "Passport"])
        #expect(!details.you[0].differs)
        #expect(details.family.map(\.relation) == [.father, .mother])
        #expect(details.family[0].details.map(\.label) == ["Name", "Date of birth"])
    }

    @Test func aDeletedFieldIsRememberedByItsID() throws {
        let doc = document("Passport")
        try detail("Height", "170 cm", on: doc)
        let fact = try #require(doc.facts.first)
        #expect(fact.fieldID == Fact.detailID(label: "Height", relation: nil, personName: nil))
        #expect(fact.displayLabel == "Height")
    }
}
