import Foundation
import Testing
@testable import Dossier

/// Your categories: the defaults, changes to the list, and what the filing model is told.
@Suite(.serialized)
struct CategoryListTests {
    init() {
        UserDefaults.standard.removeObject(forKey: CategoryList.storageKey)
    }

    @Test func hasFourteenDefaultsWithOtherLast() {
        let list = CategoryList.defaults
        #expect(list.names == ["Identity", "Immigration", "Health", "Insurance", "Money", "Taxes", "Home", "Vehicles", "Work", "Education", "Legal", "Purchases", "Travel", "Other"])
        #expect(CategoryList(json: "").names == list.names)
        #expect(CategoryList(json: "not json").names == list.names)
    }

    @Test func roundTripsAsJSON() {
        var list = CategoryList.defaults
        list.add("Pets", lines: [FilingLine(text: "Vet records")])
        #expect(CategoryList(json: list.json) == list)
    }

    @Test func addsBeforeOtherAndRefusesRepeats() {
        var list = CategoryList.defaults
        let addedPets = list.add("  Pets ")
        #expect(addedPets)
        let addedPetsAgain = list.add("pets")
        #expect(!addedPetsAgain)
        let addedBlank = list.add("   ")
        #expect(!addedBlank)
        #expect(list.names.suffix(2) == ["Pets", "Other"])
        #expect(list.category(named: "Pets")?.lines.map(\.text) == ["Pets"])
    }

    @Test func movingKeepsOtherLast() {
        var list = CategoryList.defaults
        let other = list.names.firstIndex(of: "Other")!
        list.move(fromOffsets: [other], toOffset: 0)
        #expect(list.names.last == "Other")
        let travel = list.names.firstIndex(of: "Travel")!
        list.move(fromOffsets: [travel], toOffset: 2)
        #expect(Array(list.names.prefix(3)) == ["Identity", "Immigration", "Travel"])
        #expect(list.names.last == "Other")
    }

    @Test func renameFollowsLinesAndKeepsTheOldNameAsAnAlias() {
        var list = CategoryList.defaults
        let renamedTravel = list.rename("Travel", to: "Trips")
        #expect(renamedTravel)
        #expect(list.resolve("travel") == "Trips")
        #expect(list.builtIn("Travel") == "Trips")
        #expect(list.category(named: "Insurance")?.exclusions.contains { $0.pointsTo == "Trips" } == true)
        let renamedOther = list.rename("Other", to: "Misc")
        #expect(!renamedOther)
        let renamedToIdentity = list.rename("Trips", to: "identity")
        #expect(!renamedToIdentity)
    }

    @Test func oldNamesResolveToTheirCategories() {
        let list = CategoryList.defaults
        #expect(list.resolve("Housing") == "Home")
        #expect(list.resolve("Tax and money") == "Money")
        #expect(list.resolve("HEALTH") == "Health")
        #expect(list.resolve("School") == nil)
        #expect(list.order(of: "Housing") == list.names.firstIndex(of: "Home"))
        #expect(list.order(of: "Other") == Int.max)
    }

    @Test func deletingDropsSuggestedLinesThatPointToItButKeepsYours() {
        var list = CategoryList.defaults
        var insurance = list.category(named: "Insurance")!.lines
        insurance.append(FilingLine(text: "Trip cancellation cover", pointsTo: "Travel", isYours: true))
        list.setLines(insurance, for: "Insurance")
        let deletedTravel = list.delete("Travel")
        #expect(deletedTravel)
        let deletedOther = list.delete("Other")
        #expect(!deletedOther)
        let lines = list.category(named: "Insurance")!.exclusions
        #expect(!lines.contains { $0.text == "Travel insurance" })
        #expect(lines.first { $0.text == "Trip cancellation cover" }?.pointsTo == "Other")
        #expect(list.resolve("Travel") == nil)
    }

    @Test func resetBringsBackTheDefaultLines() {
        var list = CategoryList.defaults
        list.setLines([FilingLine(text: "Only mine", isYours: true)], for: "Insurance")
        list.rename("Travel", to: "Trips")
        list.resetLines(for: "Insurance")
        let lines = list.category(named: "Insurance")!.lines
        #expect(lines.allSatisfy { !$0.isYours })
        #expect(lines.contains { $0.text == "Travel insurance" && $0.pointsTo == "Trips" })
    }

    @Test func promptListsEveryCategoryWithItsLines() {
        let text = CategoryList.defaults.promptText
        for name in CategoryList.defaults.names { #expect(text.contains("- \(name)")) }
        #expect(text.contains("Not here: Medical bills and lab results (use Health)"))
    }

    @Test func updateSavesTheList() {
        defer { UserDefaults.standard.removeObject(forKey: CategoryList.storageKey) }
        CategoryList.update { $0.add("Pets") }
        #expect(CategoryList.current.names.contains("Pets"))
        #expect(LibraryNaming.starterCategories.contains("Pets"))
    }

    @Test func aReorderIsNotAFilingChange() {
        var list = CategoryList.defaults
        let before = list.filingSignature
        list.move(fromOffsets: [0], toOffset: 5)
        #expect(list.filingSignature == before)
        list.add("Pets")
        #expect(list.filingSignature != before)
    }

    @Test func yourRuleIsSavedFirstAndPromptedBeforeTheCategories() {
        var list = CategoryList.defaults
        list.addRule("Hotel and flight bookings go in Travel", to: "travel")
        list.addRule("hotel and flight bookings go in travel", to: "Travel")
        let travel = list.category(named: "Travel")!
        #expect(travel.lines.first == FilingLine(id: travel.lines.first!.id, text: "Hotel and flight bookings go in Travel", isYours: true))
        #expect(travel.lines.filter(\.isYours).count == 1)
        let text = list.promptText
        let rule = text.range(of: "- Hotel and flight bookings go in Travel → Travel")
        let categories = text.range(of: "Categories (choose exactly one name):")
        #expect(rule != nil && categories != nil)
        if let rule, let categories { #expect(rule.lowerBound < categories.lowerBound) }
    }

    @Test func blankRuleIsNotSaved() {
        var list = CategoryList.defaults
        list.addRule("  ", to: "Travel")
        #expect(list.rules.isEmpty)
        #expect(!list.promptText.contains("owner's rules"))
    }
}
