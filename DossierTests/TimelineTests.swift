import Foundation
import PDFKit
import Testing
@testable import Dossier

struct TimelineTests {
    static func day(_ iso: String) -> SimpleDate { SimpleDate(iso: iso)! }
    let today = day("2026-09-23")

    func home(_ address: String, _ start: String, _ end: String?, licence: Bool = false) -> LifeTimeline.Home {
        .init(id: address, address: address, start: Self.day(start), end: end.map(Self.day), source: "test", fromLicence: licence)
    }

    func row(_ date: String, arrival: Bool) -> LifeTimeline.TravelRow {
        .init(id: date, date: Self.day(date), isArrival: arrival, port: "SEA")
    }

    @Test func answersWhereYouLivedAndFindsGaps() throws {
        let timeline = LifeTimeline(
            homes: [
                home("88 Pine Ave, Portland, OR 97205", "2023-01-01", nil),
                home("412 Alder St, Apt 3B, Seattle, WA 98101", "2020-08-01", "2022-07-31"),
            ],
            statuses: [], documents: [], travel: [], today: today
        )
        #expect(timeline.home(on: Self.day("2021-06-01"))?.address.hasPrefix("412 Alder") == true)
        #expect(timeline.home(on: Self.day("2022-10-01")) == nil)
        let gap = try #require(timeline.gaps.first)
        #expect(gap.start == Self.day("2022-08-01"))
        #expect(gap.end == Self.day("2022-12-31"))
        #expect(timeline.home(on: today)?.address.hasPrefix("88 Pine") == true)
    }

    @Test func closesOpenHomesAtTheNextMoveAndDropsCoveredLicenceAddresses() {
        let timeline = LifeTimeline(
            homes: [
                home("7 Birch Rd, Austin, TX 78701", "2018-09-01", nil, licence: true),
                home("412 Alder St, Seattle, WA 98101", "2020-08-01", "2022-07-31"),
                home("412 ALDER ST, SEATTLE, WA 98101", "2020-09-15", nil, licence: true),
            ],
            statuses: [], documents: [], travel: [], today: today
        )
        #expect(timeline.homes.count == 2)
        #expect(timeline.homes.first?.end == Self.day("2020-07-31"))
    }

    @Test func pairsTripsAndCountsDaysAbroadPerYear() {
        let timeline = LifeTimeline(
            homes: [], statuses: [], documents: [],
            travel: [
                row("2021-06-12", arrival: false), row("2021-07-03", arrival: true),
                row("2023-12-20", arrival: false), row("2024-01-05", arrival: true),
            ],
            today: today
        )
        #expect(timeline.trips.count == 2)
        #expect(timeline.daysAbroad(in: 2021) == 21)
        #expect(timeline.daysAbroad(in: 2023) == 12)
        #expect(timeline.daysAbroad(in: 2024) == 4)
    }

    @Test func doesNotCountATripWithAMissingReturn() {
        let timeline = LifeTimeline(
            homes: [], statuses: [], documents: [],
            travel: [row("2022-03-01", arrival: false), row("2022-05-01", arrival: false), row("2022-05-10", arrival: true)],
            today: today
        )
        #expect(timeline.trips.first?.isMissingReturn == true)
        #expect(timeline.daysAbroad(in: 2022) == 9)
    }

    @Test func treatsTheLastDepartureAsStillAway() {
        let timeline = LifeTimeline(homes: [], statuses: [], documents: [], travel: [row("2026-09-13", arrival: false)], today: today)
        #expect(timeline.trips.first?.isOngoing == true)
        #expect(timeline.daysAbroad(in: 2026) == 10)
    }
}

struct FormTests {
    func field(_ name: String, tooltip: String? = nil) -> FormFieldInfo {
        FormFieldInfo(name: name, tooltip: tooltip, page: 1)
    }

    @Test func matchesUSCISFieldNames() {
        #expect(FormFieldMatcher.match(field("form1[0].#subform[0].Pt2Line1a_FamilyName[0]")) == .familyName)
        #expect(FormFieldMatcher.match(field("form1[0].#subform[0].Pt2Line1b_GivenName[0]")) == .givenName)
        #expect(FormFieldMatcher.match(field("Pt2Line7_AlienNumber[0]")) == .alienNumber)
        #expect(FormFieldMatcher.match(field("Pt2Line20a_PassportNumber[0]")) == .passportNumber)
        #expect(FormFieldMatcher.match(field("Pt2Line21_DateOfLastArrival[0]")) == .lastArrivalDate)
        #expect(FormFieldMatcher.match(field("Pt2Line5_AptSteFlrNumber[0]")) == .unit)
        #expect(FormFieldMatcher.match(field("Pt2Line5_CityOrTown[0]")) == .city)
        #expect(FormFieldMatcher.match(field("Pt2Line5_ZipCode[0]")) == .postalCode)
        #expect(FormFieldMatcher.match(field("Pt2Line18_CityTownOfBirth[0]")) == .placeOfBirth)
    }

    @Test func usesTooltipsAndSkipsOtherPeople() {
        #expect(FormFieldMatcher.match(field("TextField12", tooltip: "Date of Birth (mm/dd/yyyy)")) == .dateOfBirth)
        #expect(FormFieldMatcher.match(field("Pt2Line2a_FamilyName[0]", tooltip: "Other Names Used. Family Name")) == nil)
        #expect(FormFieldMatcher.match(field("Pt3Line7_Signature[0]")) == nil)
    }

    @Test func splitsAddresses() {
        let parts = AddressParts("412 Alder St, Apt 3B, Seattle, WA 98101")
        #expect(parts == AddressParts(street: "412 Alder St", unit: "3B", city: "Seattle", state: "WA", postalCode: "98101"))
        let inline = AddressParts("88 Pine Ave Apt 12, Portland, OR 97205-1234")
        #expect(inline.street == "88 Pine Ave")
        #expect(inline.unit == "12")
        #expect(inline.postalCode == "97205")
    }

    @Test func readsAndFillsTheSampleForm() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "SampleDocuments/Sample application form.pdf")
        let document = try #require(PDFDocument(url: url))
        let fields = FormFiller.fields(in: document)
        #expect(fields.count == 14)
        let matched = fields.compactMap(FormFieldMatcher.match)
        #expect(matched.count == 12, "eligibility category and signature are left for the user")
        let family = try #require(fields.first { $0.name.contains("FamilyName") })
        let data = try #require(FormFiller.fill(document, values: [family.name: "ERIKSSON"]))
        let filled = try #require(PDFDocument(data: data))
        let value = filled.page(at: 0)?.annotations.first { $0.fieldName == family.name }?.widgetStringValue
        #expect(value == "ERIKSSON")
    }

    @Test func formatsDatesTheWayTheFieldAsks() {
        let date = SimpleDate(iso: "1990-08-12")!
        #expect(FormDateStyle.style(for: field("DOB")).format(date) == "08/12/1990")
        #expect(FormDateStyle.style(for: field("x", tooltip: "Date (YYYY-MM-DD)")).format(date) == "1990-08-12")
    }
}
