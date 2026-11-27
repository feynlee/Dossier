import Foundation
import Testing
@testable import Dossier

/// Custom fields: what a document is read with, and how that reaches the prompt.
@Suite(.serialized)
struct ReadingFieldsTests {
    private let lease = ReadingFields(fields: [
        AskedField(name: "Landlord’s phone"),
        AskedField(name: "Pets allowed", hint: "yes, no, or the conditions"),
    ])

    init() {
        UserDefaults.standard.removeObject(forKey: FieldRules.rulesKey)
    }

    @Test func roundTripsAsJSON() {
        #expect(ReadingFields(json: lease.json) == lease)
        #expect(ReadingFields(json: nil) == nil)
        #expect(ReadingFields(json: "not json") == nil)
    }

    @Test func addingSkipsBlankAndRepeatedNames() {
        var fields = ReadingFields()
        let first = fields.add("  Late fee ")
        let repeated = fields.add("late fee")
        let blank = fields.add("   ")
        #expect(first)
        #expect(!repeated)
        #expect(!blank)
        #expect(fields.fields.map(\.name) == ["Late fee"])
    }

    @Test func ownFieldsComeFirstThenTheCategoryRuleThenTheDefault() {
        FieldRules.set(ReadingFields(fields: [AskedField(name: "Security deposit")]), for: "Housing")
        defer { FieldRules.set(nil, for: "Housing") }

        #expect(FieldRules.source(own: lease, category: "Housing") == .own(lease))
        #expect(FieldRules.source(own: nil, category: "Housing").shortTag == "Housing rule")
        #expect(FieldRules.source(own: nil, category: "Health") == .standard)
        #expect(FieldRules.source(own: nil, category: nil) == .standard)
        // Choosing the default for one file: empty own fields that read everything useful.
        #expect(FieldRules.source(own: ReadingFields(), category: "Housing") == .standard)
    }

    @Test func anEmptyRuleThatReadsEverythingIsRemoved() {
        FieldRules.set(ReadingFields(fields: [AskedField(name: "Parking")]), for: "Housing")
        FieldRules.set(ReadingFields(), for: "Housing")
        #expect(FieldRules.rule(for: "Housing") == nil)
    }

    @Test func requestAsksForTheFieldsAndCanLeaveOutEverythingElse() {
        let withUseful = DetailRequest.reading(lease)
        #expect(withUseful.asked == lease.fields)
        #expect(withUseful.readsContents)

        var only = lease
        only.readsUseful = false
        let request = DetailRequest.reading(only)
        #expect(!request.readsContents)
        #expect(!request.findsUsefulDetails)
        #expect(request.requested.isEmpty)
        #expect(!request.isEmpty)

        let prompt = DocumentExtractor.instructions(for: request)
        #expect(prompt.contains("\"Pets allowed\" (yes, no, or the conditions)"))
        #expect(prompt.contains("leave contents empty"))

        let device = OnDeviceReader.partInstructions(kind: "lease", title: "Lease", known: "", request: request)
        #expect(device.contains("Leave contents empty"))
        #expect(device.contains("\"Landlord’s phone\""))
    }

    @Test func defaultRequestIsUnchanged() {
        let request = DetailRequest.reading(nil)
        #expect(request.asked.isEmpty)
        #expect(request.readsContents)
        #expect(!DocumentExtractor.instructions(for: request).contains("leave contents empty"))
    }

    @Test func suggestionsFitTheKind() {
        #expect(FieldRules.suggestions(for: .lease, category: "Housing").contains("Security deposit"))
        #expect(FieldRules.standardFieldNames(for: .lease) == DocumentKind.lease.importantKeys.map(\.label))
    }
}
