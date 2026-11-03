import Foundation
import Testing
@testable import Dossier

struct DocumentLifecycleTests {
    let today = SimpleDate(iso: "2026-11-03")!

    func entry(_ id: String, series: String? = "Li|passport|chn", from: String? = nil, until: String? = nil) -> DocumentLifecycle.Entry {
        let end = until.flatMap(SimpleDate.init(iso:))
        return DocumentLifecycle.Entry(
            id: id, series: series, from: from.flatMap(SimpleDate.init(iso:)), until: end,
            isExpired: end.map { $0 < today } ?? false, expiredOn: end
        )
    }

    @Test func renewedDocumentEndsWhenItsRenewalStarts() {
        let statuses = DocumentLifecycle.statuses([
            entry("old", from: "2014-03-14", until: "2024-03-13"),
            entry("new", from: "2023-09-01", until: "2033-08-31"),
        ], today: today)
        #expect(statuses["old"] == .renewed(ended: SimpleDate(iso: "2023-09-01")))
        #expect(statuses["new"] == .current)
    }

    @Test func eachVersionEndsWhenTheNextOneStarts() {
        let statuses = DocumentLifecycle.statuses([
            entry("2022", series: "Mei|employmentAuthorization", from: "2022-05-01", until: "2024-04-30"),
            entry("2020", series: "Mei|employmentAuthorization", from: "2020-05-01", until: "2022-04-30"),
            entry("2024", series: "Mei|employmentAuthorization", from: "2024-04-15", until: "2026-12-31"),
        ], today: today)
        // A gap: the 2020 card ran out before the 2022 one started, so it ended on its printed date.
        #expect(statuses["2020"] == .renewed(ended: SimpleDate(iso: "2022-04-30")))
        #expect(statuses["2022"] == .renewed(ended: SimpleDate(iso: "2024-04-15")))
        #expect(statuses["2024"] == .current)
    }

    @Test func naturallyExpiredIsNotRenewed() {
        let statuses = DocumentLifecycle.statuses([
            entry("licence", series: "Li|driversLicense", from: "2015-01-30", until: "2021-01-30"),
            entry("visa", series: nil, from: "2018-01-01", until: "2020-01-01"),
        ], today: today)
        #expect(statuses["licence"] == .expired(on: SimpleDate(iso: "2021-01-30")))
        #expect(statuses["visa"] == .expired(on: SimpleDate(iso: "2020-01-01")))
    }

    @Test func renewalThatHasNotStartedLeavesTheOldOneInUse() {
        let statuses = DocumentLifecycle.statuses([
            entry("old", series: "Li|employmentAuthorization", from: "2024-12-01", until: "2026-11-30"),
            entry("new", series: "Li|employmentAuthorization", from: "2026-12-01", until: "2028-11-30"),
        ], today: today)
        // It ends on its printed date, a day before the new card starts.
        #expect(statuses["old"] == .renewing(until: SimpleDate(iso: "2026-11-30")!))
        #expect(statuses["old"]?.isEnded == false)
    }

    @Test func copiesWithTheSameDatesAreTheSameVersion() {
        let statuses = DocumentLifecycle.statuses([
            entry("front", series: "Li|greenCard", from: "2020-01-01", until: "2030-01-01"),
            entry("back", series: "Li|greenCard", from: "2020-01-01", until: "2030-01-01"),
        ], today: today)
        #expect(statuses["front"] == .current)
        #expect(statuses["back"] == .current)
    }

    @Test func greenCardRenewalKeepsThePrintedEndWhenTheStartDoesNotMove() {
        // Both cards carry the same resident-since date, so it says nothing about when the old one ended.
        let statuses = DocumentLifecycle.statuses([
            entry("old", series: "Li|greenCard", from: "2016-05-01", until: "2026-05-01"),
            entry("new", series: "Li|greenCard", from: "2016-05-01", until: "2036-05-01"),
        ], today: today)
        #expect(statuses["old"] == .renewed(ended: SimpleDate(iso: "2026-05-01")))
    }

    @Test func seriesKeepsDifferentCountriesAndHomesApart() {
        let china = DocumentLifecycle.series(kind: .passport, person: "Li", nationality: "CHN", address: nil)
        let usa = DocumentLifecycle.series(kind: .passport, person: "Li", nationality: "USA", address: nil)
        #expect(china != usa)
        let lease1 = DocumentLifecycle.series(kind: .lease, person: "Household", nationality: nil, address: "88 Pine Ave, Apt 4, Seattle")
        let lease2 = DocumentLifecycle.series(kind: .lease, person: "Household", nationality: nil, address: "88 pine ave, Seattle WA")
        let lease3 = DocumentLifecycle.series(kind: .lease, person: "Household", nationality: nil, address: "12 Oak St, Seattle")
        #expect(lease1 == lease2)
        #expect(lease1 != lease3)
        #expect(DocumentLifecycle.series(kind: .visa, person: "Li", nationality: nil, address: nil) == nil)
        #expect(DocumentLifecycle.series(kind: .uscisNotice, person: "Li", nationality: nil, address: nil) == nil)
    }

    @Test func foldersListDocumentsInUseFirstAndFoldersThatEndedLast() {
        func place(_ folder: String, _ name: String) -> LibraryPlacement {
            LibraryPlacement(person: "Li", category: "Identity", folder: folder, name: name)
        }
        let status: [String: DocumentLifecycle.Status] = [
            "p2014": .renewed(ended: SimpleDate(iso: "2023-09-01")),
            "p2023": .current,
            "p2004": .renewed(ended: SimpleDate(iso: "2014-03-14")),
            "dl": .expired(on: SimpleDate(iso: "2021-01-30")),
            "id": .current,
        ]
        let items: [(item: String, placement: LibraryPlacement)] = [
            ("p2004", place("Passports", "Li · Passport · 2004")),
            ("p2014", place("Passports", "Li · Passport · 2014")),
            ("p2023", place("Passports", "Li · Passport · 2023")),
            ("dl", place("Driver’s licences", "Li · Driver’s licence · 2015")),
            ("id", place("State IDs", "Li · State ID · 2022")),
        ]
        let sections = LibraryGroups.sections(items, person: nil, status: { status[$0] ?? .current })
        #expect(sections.count == 1)
        #expect(sections[0].folders.map(\.name) == ["Passports", "State IDs", "Driver’s licences"])
        #expect(sections[0].folders[0].items == ["p2023", "p2014", "p2004"])
    }
}
