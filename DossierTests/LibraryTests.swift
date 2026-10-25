import Foundation
import Testing
@testable import Dossier

struct LibraryTests {
    func facts(_ kind: DocumentKind, title: String = "", given: String? = nil, surname: String? = nil, category: String? = nil,
               form: String? = nil, address: String? = nil, from: String? = nil, until: String? = nil, date: String? = nil) -> LibraryFacts {
        LibraryFacts(
            kind: kind, title: title, givenNames: given, surname: surname, category: category, formType: form, address: address,
            from: from.flatMap(SimpleDate.init(iso:)), until: until.flatMap(SimpleDate.init(iso:)), date: date.flatMap(SimpleDate.init(iso:)),
            side: nil, fileExtension: "pdf"
        )
    }

    func entry(_ id: String, _ facts: LibraryFacts, current: LibraryPlacement? = nil, isYours: Bool = false) -> LibraryEntry {
        LibraryEntry(id: id, facts: facts, current: current, isYours: isYours)
    }

    // MARK: Names

    @Test func namesKnownKindsWithPersonTypeDetailAndDates() {
        let ead = facts(.employmentAuthorization, given: "MEI LING", category: "(c)(9)", from: "2024-05-01", until: "2026-04-30")
        #expect(LibraryNaming.name(for: ead, person: "Mei") == "Mei · EAD card C09 · 2024-05-01 to 2026-04-30")

        let passport = facts(.passport, given: "LI", from: "2019-03-14", until: "2029-03-14")
        #expect(LibraryNaming.name(for: passport, person: "Li") == "Li · Passport · 2019-03-14 to 2029-03-14")

        let lease = facts(.lease, address: "88 Pine Ave, Apt 4, Seattle, WA", from: "2021-06-01", until: "2022-05-31")
        #expect(LibraryNaming.name(for: lease, person: "Household") == "Household · Lease 88 Pine Ave · 2021-06-01 to 2022-05-31")

        var back = ead
        back.side = "back"
        #expect(LibraryNaming.name(for: back, person: "Mei").hasSuffix("2026-04-30 (back)"))
    }

    @Test func writesCategoriesAndDatesConsistently() {
        #expect(LibraryNaming.compactCategory("(c)(9)") == "C09")
        #expect(LibraryNaming.compactCategory("C9") == "C09")
        #expect(LibraryNaming.compactCategory("A17") == "A17")
        #expect(LibraryNaming.dates(for: facts(.other, date: "2023-10-02")) == "2023-10-02")
        #expect(LibraryNaming.dates(for: facts(.other)) == nil)
        #expect(LibraryNaming.clean("I-20 / F-1:  school") == "I-20 F-1 school")
        #expect(LibraryNaming.unique("Li · Passport", among: ["Li · Passport", "Li · Passport (2)"]) == "Li · Passport (3)")
    }

    @Test func spotsNumbersThatMustNotBeInNames() {
        #expect(LibraryNaming.mayRevealNumber("A123456789"))
        #expect(LibraryNaming.mayRevealNumber("Account 4821 9930 1123"))
        #expect(!LibraryNaming.mayRevealNumber("2024-05-01 to 2026-04-30"))
        #expect(!LibraryNaming.mayRevealNumber("Tax year 2023"))
    }

    // MARK: People

    @Test func peopleComeFromFirstNamesWithTheOwnerForUnnamedDocuments() {
        let entries = [
            entry("1", facts(.passport, given: "Li")),
            entry("2", facts(.greenCard, given: "LI")),
            entry("3", facts(.employmentAuthorization, given: "Mei Ling")),
            entry("4", facts(.other, title: "Vaccination record")),
            entry("5", facts(.lease)),
        ]
        #expect(LibraryPlanner.owner(of: entries) == "Li")
        #expect(LibraryPlanner.person(for: entries[2], owner: "Li", among: entries) == "Mei")
        #expect(LibraryPlanner.person(for: entries[3], owner: "Li", among: entries) == "Li")
        #expect(LibraryPlanner.person(for: entries[4], owner: "Li", among: entries) == "Household")
    }

    @Test func peopleWithTheSameFirstNameGetAnInitial() {
        let entries = [entry("1", facts(.passport, given: "Wei", surname: "Zhang")), entry("2", facts(.passport, given: "Wei", surname: "Li"))]
        #expect(LibraryPlanner.person(for: entries[0], owner: nil, among: entries) == "Wei Z")
        #expect(LibraryPlanner.person(for: entries[1], owner: nil, among: entries) == "Wei L")
    }

    // MARK: Planning

    @Test func placesKnownKindsByRuleAndOthersWhereTheModelSays() {
        let entries = [
            entry("ead", facts(.employmentAuthorization, given: "Mei", category: "C09", from: "2024-05-01", until: "2026-04-30")),
            entry("i20", facts(.other, title: "Form I-20", given: "Li", date: "2019-08-15")),
        ]
        #expect(LibraryPlanner.needsModel(entries).map(\.id) == ["i20"])
        let plan = LibraryPlanner.plan(entries, model: ["i20": ModelPlacement(category: "Immigration", folder: "I-20s", type: "I-20", detail: "SEVIS N0012345678")])
        #expect(plan["ead"] == LibraryPlacement(person: "Mei", category: "Immigration", folder: "EAD cards", name: "Mei · EAD card C09 · 2024-05-01 to 2026-04-30"))
        // The model's detail held a number, so it's left out.
        #expect(plan["i20"] == LibraryPlacement(person: "Li", category: "Immigration", folder: "I-20s", name: "Li · I-20 · 2019-08-15"))
    }

    @Test func keepsYourPlacementsAndNumbersRepeatedNames() {
        let yours = LibraryPlacement(person: "Li", category: "Travel", folder: "Passports", name: "My old passport")
        let entries = [
            entry("a", facts(.passport, given: "Li", until: "2029-03-14")),
            entry("b", facts(.passport, given: "Li", until: "2029-03-14")),
            entry("c", facts(.passport, given: "Li"), current: yours, isYours: true),
        ]
        let plan = LibraryPlanner.plan(entries, model: [:])
        #expect(plan["c"] == yours)
        #expect(plan["a"]?.name == "Li · Passport · to 2029-03-14")
        #expect(plan["b"]?.name == "Li · Passport · to 2029-03-14 (2)")
    }

    @Test func aNewLayoutMovesFoldersButNotYours() {
        let current = LibraryPlacement(person: "Li", category: "School", folder: "I-20s", name: "Li · I-20 · 2019-08-15")
        let yours = LibraryPlacement(person: "Li", category: "School", folder: "Mine", name: "Kept")
        let entries = [
            entry("i20", facts(.other, title: "I-20", given: "Li", date: "2019-08-15"), current: current),
            entry("mine", facts(.other, title: "Transcript", given: "Li"), current: yours, isYours: true),
        ]
        let moves = [FolderKey(category: "School", folder: "I-20s"): FolderKey(category: "Education", folder: "I-20s")]
        let plan = LibraryPlanner.plan(entries, model: [:], moves: moves)
        #expect(plan["i20"] == LibraryPlacement(person: "Li", category: "Education", folder: "I-20s", name: "Li · I-20 · 2019-08-15"))
        #expect(plan["mine"] == yours)
    }

    @Test func asksForANewLayoutOnlyWhenTheTopLevelOutgrowsItsShape() {
        let summary = { (categories: [String]) in
            categories.map { LibraryPlanner.FolderSummary(key: FolderKey(category: $0, folder: "F"), count: 1, examples: []) }
        }
        #expect(!LibraryPlanner.needsNewLayout(summary(["Identity", "Immigration"])))
        #expect(LibraryPlanner.needsNewLayout(summary((1...9).map { "C\($0)" })))
        #expect(LibraryPlanner.needsNewLayout(summary(["A", "B", "C", "D", "E"])))

        let folders = summary((1...9).map { "C\($0)" })
        let tooMany = Dictionary(uniqueKeysWithValues: folders.map { ($0.key, FolderKey(category: "X\($0.key.category)", folder: "F")) })
        #expect(LibraryPlanner.validated(tooMany, for: folders).isEmpty)
        let merged = Dictionary(uniqueKeysWithValues: folders.map { ($0.key, FolderKey(category: "All", folder: $0.key.category)) })
        #expect(LibraryPlanner.validated(merged, for: folders).count == 9)
    }

    // MARK: Vault

    @Test func vaultSectionsFollowTheLibraryForOnePersonOrEveryone() {
        let items: [(item: String, placement: LibraryPlacement)] = [
            ("passport", LibraryPlacement(person: "Li", category: "Identity", folder: "Passports", name: "Li · Passport")),
            ("i20a", LibraryPlacement(person: "Li", category: "Immigration", folder: "I-20s", name: "Li · I-20 · 2019")),
            ("i20b", LibraryPlacement(person: "Li", category: "Immigration", folder: "I-20s", name: "Li · I-20 · 2020")),
            ("ead", LibraryPlacement(person: "Mei", category: "Immigration", folder: "EAD cards", name: "Mei · EAD card")),
            ("lease", LibraryPlacement(person: "Household", category: "Housing", folder: "Leases", name: "Household · Lease")),
        ]
        #expect(LibraryGroups.people(items.map(\.placement), owner: "Li") == ["Li", "Mei", "Household"])

        let li = LibraryGroups.sections(items, person: "Li")
        #expect(li.map(\.id) == ["Identity", "Immigration", "Housing · shared"])
        #expect(li[1].folders.map(\.name) == ["I-20s"])
        #expect(li[1].folders[0].items == ["i20a", "i20b"])

        let everyone = LibraryGroups.sections(items, person: nil)
        #expect(everyone.map(\.id) == ["Identity", "Immigration", "Housing"])
        #expect(everyone[1].folders.map(\.name) == ["EAD cards", "I-20s"])
        #expect(LibraryGroups.years([SimpleDate(iso: "2019-08-15")!, SimpleDate(iso: "2022-01-02")!]) == "2019 to 2022")
    }
}

struct LibraryFolderTests {
    @Test func filesGoUnderPersonCategoryAndFolder() {
        let root = URL(filePath: "/tmp/Dossier/Documents", directoryHint: .isDirectory)
        let placement = LibraryPlacement(person: "Mei", category: "Immigration", folder: "EAD cards", name: "Mei · EAD card C09 · 2024-05-01 to 2026-04-30")
        #expect(LibraryFolder.destination(for: placement, showingPerson: true, fileExtension: "jpg", root: root).path
            == "/tmp/Dossier/Documents/Mei/Immigration/EAD cards/Mei · EAD card C09 · 2024-05-01 to 2026-04-30.jpg")
        #expect(LibraryFolder.destination(for: placement, showingPerson: false, fileExtension: "", root: root).path
            == "/tmp/Dossier/Documents/Immigration/EAD cards/Mei · EAD card C09 · 2024-05-01 to 2026-04-30.pdf")
        #expect(LibraryFolder.contains(URL(filePath: "/tmp/Dossier/Documents/Scan.pdf"), root: root))
        #expect(!LibraryFolder.contains(URL(filePath: "/tmp/Dossier/Elsewhere.pdf"), root: root))
    }

    @Test func movesAFileWithoutReplacingAnother() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scan = root.appending(path: "Scan.pdf")
        try Data("new".utf8).write(to: scan)
        let destination = root.appending(path: "Identity/Passports/Li · Passport.pdf")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)

        let moved = try #require(LibraryFolder.move(scan, to: destination))
        #expect(moved.lastPathComponent == "Li · Passport (2).pdf")
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(try Data(contentsOf: moved) == Data("new".utf8))
        // Moving it to where it already is leaves it alone.
        #expect(LibraryFolder.move(moved, to: destination) == moved)
    }

    @Test func showsDossiersOwnFolderByName() {
        let url = URL(filePath: "/private/var/mobile/Library/Mobile Documents/iCloud~liziyue~Dossier/Documents/Mei/Immigration")
        #expect(FolderAccess.displayPath(for: url) == "iCloud Drive › Dossier › Mei › Immigration")
    }
}
