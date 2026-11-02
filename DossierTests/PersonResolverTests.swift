import Foundation
import Testing
@testable import Dossier

/// Seen on a real vault: one person filed as three, "Ziyue", "Zi" and "紫玥", from a passport, a form that
/// printed the pinyin with a space, and a Chinese document.
struct PersonResolverTests {
    func entry(_ id: String, _ kind: DocumentKind = .passport, given: String?, surname: String? = nil, born: String? = nil,
               aNumber: String? = nil, title: String = "") -> LibraryEntry {
        var facts = LibraryFacts(kind: kind, title: title, givenNames: given, surname: surname, category: nil, formType: nil, address: nil,
                                 from: nil, until: nil, date: nil, side: nil, fileExtension: "pdf")
        facts.dateOfBirth = born.flatMap(SimpleDate.init(iso:))
        facts.identityKeys = aNumber.map { ["A|\($0)"] } ?? []
        return LibraryEntry(id: id, facts: facts, current: nil)
    }

    var vault: [LibraryEntry] {
        [
            entry("passport", given: "ZIYUE", surname: "LI", born: "1990-03-02"),
            entry("ead", .employmentAuthorization, given: "ZIYUE", surname: "LI", born: "1990-03-02"),
            entry("i797", .uscisNotice, given: "ZI YUE", surname: "LI"),
            entry("hukou", .other, given: "紫玥", surname: "李", born: "1990-03-02", title: "户口簿"),
            entry("mei", .passport, given: "MEI LING", surname: "CHEN", born: "1992-11-20"),
            entry("lease", .lease, given: nil),
        ]
    }

    @Test func writesNamesInLatinLetters() {
        #expect(PersonResolver.key("紫玥") == "ZIYUE")
        #expect(PersonResolver.key("紫 玥") == "ZIYUE")
        #expect(PersonResolver.key("Zi Yue") == "ZIYUE")
        #expect(PersonResolver.key("José") == "JOSE")
    }

    @Test func oneGroupForEveryWayTheNameIsPrinted() throws {
        let groups = PersonResolver.groups(vault)
        #expect(groups.count == 2)
        let ziyue = try #require(groups.first { $0.members.contains("passport") })
        #expect(ziyue.members == ["ead", "hukou", "i797", "passport"])
        #expect(ziyue.firstName == "Ziyue")
        let names = PersonResolver.names(for: groups)
        #expect(names["i797"] == "Ziyue")
        #expect(names["hukou"] == "Ziyue")
        #expect(names["mei"] == "Mei")
    }

    @Test func theLibraryFilesThemUnderOnePerson() {
        let plan = LibraryPlanner.plan(vault, model: ["hukou": ModelPlacement(category: "Identity", folder: "Household registers", type: "Hukou", detail: nil)])
        #expect(Set(["passport", "ead", "i797", "hukou"].compactMap { plan[$0]?.person }) == ["Ziyue"])
        #expect(LibraryPlanner.owner(of: vault) == "Ziyue")
        #expect(plan["lease"]?.person == LibraryPlacement.household)
    }

    @Test func aChineseNameWithTheFamilyNameInItStillMatches() {
        let groups = PersonResolver.groups([entry("1", given: "ZIYUE", surname: "LI"), entry("2", .other, given: "李紫玥")])
        #expect(groups.count == 1)
        #expect(groups.first?.firstName == "Ziyue")
    }

    @Test func aShortenedNameJoinsOnlyWhenTheFamilyNameOrBirthDateAgrees() {
        #expect(PersonResolver.groups([entry("1", given: "ZIYUE", surname: "LI"), entry("2", given: "ZI", surname: "LI")]).count == 1)
        #expect(PersonResolver.groups([entry("1", given: "ZIYUE", surname: "LI"), entry("2", given: "ZI", surname: "WANG")]).count == 2)
        #expect(PersonResolver.groups([entry("1", given: "ZIYUE"), entry("2", given: "ZI")]).count == 2)
    }

    @Test func differentBirthDatesAreDifferentPeople() {
        let twins = [entry("1", given: "WEI", surname: "LI", born: "2015-01-01"), entry("2", given: "WEI", surname: "LI", born: "2016-01-01")]
        #expect(PersonResolver.groups(twins).count == 2)
    }

    @Test func middleNamesStayMiddleNames() {
        #expect(PersonResolver.groups([entry("1", given: "MARY ANN", surname: "SMITH")]).first?.firstName == "Mary")
        #expect(PersonResolver.groups([entry("1", given: "MEI LING"), entry("2", .employmentAuthorization, given: "Mei Ling")]).first?.firstName == "Mei")
    }

    @Test func onlyChineseNamesKeepTheirCharacters() {
        let groups = PersonResolver.groups([entry("1", .other, given: "紫玥"), entry("2", .other, given: "紫 玥")])
        #expect(groups.count == 1)
        #expect(groups.first?.firstName == "紫玥")
    }

    @Test func theSameANumberIsTheSamePerson() {
        let groups = PersonResolver.groups([entry("1", .greenCard, given: "ZIYUE", aNumber: "x"), entry("2", .uscisNotice, given: "JOY", aNumber: "x")])
        #expect(groups.count == 1)
    }

    @Test func theModelMayJoinPeopleTheDocumentsAllow() {
        let entries = [entry("1", given: "ZIYUE", surname: "LI"), entry("2", .other, given: "JOY ZIYUE"), entry("3", given: "MEI", surname: "CHEN")]
        let groups = PersonResolver.groups(entries)
        #expect(groups.count == 3)
        let number = { (id: String) in groups.firstIndex { $0.members.contains(id) }! + 1 }
        let reviewed = PersonResolver.applying([
            PersonDecision(numbers: [number("1"), number("2")], firstName: "ziyue"),
            PersonDecision(numbers: [number("3")], firstName: "Mei"),
        ], to: groups, entries: entries)
        let names = PersonResolver.names(for: reviewed)
        #expect(names["1"] == "Ziyue" && names["2"] == "Ziyue")
        #expect(names["3"] == "Mei")
    }

    @Test func theModelCantJoinPeopleTheDocumentsTellApart() {
        let entries = [entry("1", given: "ZIYUE", surname: "LI", born: "1990-03-02"), entry("2", given: "MEI", surname: "CHEN", born: "1992-11-20")]
        let groups = PersonResolver.groups(entries)
        let reviewed = PersonResolver.applying([PersonDecision(numbers: [1, 2], firstName: "Ziyue")], to: groups, entries: entries)
        #expect(reviewed.count == 2)
    }

    @Test func theModelCantMakeUpAName() {
        let entries = [entry("1", given: "ZI YUE", surname: "LI"), entry("2", given: "MEI", surname: "CHEN")]
        let groups = PersonResolver.groups(entries)
        let first = groups.firstIndex { $0.members.contains("1") }! + 1
        let reviewed = PersonResolver.applying([PersonDecision(numbers: [first], firstName: "Joanna")], to: groups, entries: entries)
        #expect(PersonResolver.names(for: reviewed)["1"] == "Zi")
        let renamed = PersonResolver.applying([PersonDecision(numbers: [first], firstName: "Ziyue")], to: groups, entries: entries)
        #expect(PersonResolver.names(for: renamed)["1"] == "Ziyue")
    }
}
