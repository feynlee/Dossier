import Foundation
import Testing
import WebKit
@testable import Dossier

/// Loads the sample web form into a real web view and fills it, so the page scripts are tested end to end.
@MainActor
struct WebFillTests {
    func load() async throws -> WebFillSession {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "SampleDocuments/Sample web form.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let session = WebFillSession()
        await withCheckedContinuation { continuation in
            session.onPageLoaded = { continuation.resume() }
            session.webView.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        }
        return session
    }

    func entry(_ slot: String, _ value: String, kind: FormValueKind = .text, row: Int? = nil) throws -> FormEntry {
        FormEntry(slot: slot, row: row, label: slot, group: "Test", kind: kind, isSensitive: false, sealed: try Sealer.shared.seal(value, sensitive: false))
    }

    func value(_ id: String, in session: WebFillSession) async throws -> String {
        try await session.webView.evaluateJavaScript("document.getElementById('\(id)').value") as? String ?? ""
    }

    @Test func readsAndFillsAWholePage() async throws {
        let session = try await load()
        let fields = await session.scan()
        #expect(fields.contains { $0.label == "Surnames" && $0.context.contains("Personal information") })
        let sex = try #require(fields.first { $0.inputType == "radio" })
        #expect(sex.options == ["Male", "Female"])
        #expect(sex.label == "Sex")
        #expect(fields.contains { $0.inputType == "file" })

        let catalog = FormCatalog(entries: [
            try entry("you.familyName", "ERIKSSON"), try entry("you.givenName", "ANNA"), try entry("you.givenNames", "ANNA MARIA"),
            try entry("you.dateOfBirth", "1990-08-12", kind: .date), try entry("you.sex", "F", kind: .sex),
            try entry("you.cityOfBirth", "STOCKHOLM"), try entry("you.nationality", "SWEDEN", kind: .country),
            try entry("passport.expiryDate", "2029-03-14", kind: .date),
            try entry("address.street", "88 Pine Ave"), try entry("address.city", "Portland"), try entry("address.postalCode", "97205"),
            try entry("previousAddress.street", "412 Alder St", row: 0), try entry("previousAddress.city", "Seattle", row: 0),
            try entry("previousAddress.street", "1 Main St", row: 1), try entry("previousAddress.city", "Boston", row: 1),
            try entry("previousAddress.street", "9 Elm St", row: 2), try entry("previousAddress.city", "Austin", row: 2),
            try entry("family.spouse.familyName", "LINDQVIST"), try entry("family.spouse.dateOfBirth", "1988-01-02", kind: .date),
            try entry("family.father.fullName", "ERIK ERIKSSON"), try entry("you.detail.email", "anna@example.com"),
        ])
        let slots = Set(catalog.slots.map(\.slot))
        var matches: [String: FieldMatch] = [:]
        for field in fields where field.inputType != "file" {
            if let match = FormMatcher.match(field, slots: slots) { matches[field.id] = match }
        }
        let assignment = FormMatcher.assign(fields, matches: matches, catalog: catalog)
        #expect(assignment.remaining["Previous addresses"] == 1)

        var values: [String: [String]] = [:]
        for field in fields {
            guard let id = assignment.entries[field.id], let entry = catalog.entry(id), let value = catalog.value(of: entry, context: nil) else { continue }
            values[field.id] = FormMatcher.candidates(for: value, kind: entry.kind, part: matches[field.id]?.part, field: field)
        }
        let results = await session.fill(values)
        #expect(results.values.allSatisfy { $0 })

        #expect(try await value("surname", in: session) == "ERIKSSON")
        #expect(try await value("given", in: session) == "ANNA MARIA")
        #expect(try await value("dobDay", in: session) == "12")
        #expect(try await value("dobMonth", in: session) == "AUG")
        #expect(try await value("dobYear", in: session) == "1990")
        #expect(try await session.webView.evaluateJavaScript("document.getElementById('sexF').checked") as? Bool == true)
        #expect(try await value("pobCity", in: session) == "STOCKHOLM")
        #expect(try await value("nat", in: session) == "SWEDEN")
        #expect(try await value("ppx", in: session) == "03/14/2029")
        #expect(try await value("street", in: session) == "88 Pine Ave")
        #expect(try await value("prev0", in: session) == "412 Alder St")
        #expect(try await value("prev1city", in: session) == "Boston")
        #expect(try await value("spouseSurname", in: session) == "LINDQVIST")
        #expect(try await value("spouseDob", in: session) == "01/02/1988")
        #expect(try await value("father", in: session) == "ERIK ERIKSSON")
        #expect(try await value("email", in: session) == "anna@example.com")
        // An eligibility question is left alone.
        #expect(try await value("ineligible", in: session) == "")
    }

    /// After "Add another" adds a row, filling again puts the next address in it, and leaves the rows
    /// already filled alone.
    @Test func continuesWithTheNextRow() async throws {
        let session = try await load()
        let catalog = FormCatalog(entries: [
            try entry("previousAddress.street", "412 Alder St", row: 0), try entry("previousAddress.street", "1 Main St", row: 1),
            try entry("previousAddress.street", "9 Elm St", row: 2),
        ])
        func fillPage() async {
            let fields = await session.scan()
            var matches: [String: FieldMatch] = [:]
            for field in fields { if let match = FormMatcher.match(field, slots: ["previousAddress.street"]) { matches[field.id] = match } }
            let assignment = FormMatcher.assign(fields, matches: matches, catalog: catalog)
            var values: [String: [String]] = [:]
            for field in fields where field.currentValue.isEmpty {
                guard let id = assignment.entries[field.id], let entry = catalog.entry(id), let value = catalog.value(of: entry, context: nil) else { continue }
                values[field.id] = [value]
            }
            _ = await session.fill(values)
        }
        await fillPage()
        // The site's "Add another" button adds a third row.
        _ = try await session.webView.evaluateJavaScript("""
            const row = document.createElement('div');
            row.innerHTML = '<label for="prev2">Street address</label><input id="prev2" name="dtlPrevAddr$ctl02$tbxStreet">';
            document.getElementById('prev1city').after(row); true
            """)
        await fillPage()
        #expect(try await value("prev0", in: session) == "412 Alder St")
        #expect(try await value("prev2", in: session) == "9 Elm St")
    }
}

struct AutoFillStoreTests {
    /// The list AutoFill reads keeps values sealed, and opens to the same values with the vault key.
    @Test func keepsSealedValuesForTheExtension() throws {
        let entry = FormEntry(slot: "you.familyName", label: "Family name", group: "You", kind: .text, isSensitive: false, sealed: try Sealer.shared.seal("ERIKSSON", sensitive: false))
        AutoFillStore.save([entry])
        defer { AutoFillStore.clear() }
        let snapshot = try #require(AutoFillStore.load())
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].sealed != Data("ERIKSSON".utf8))
        #expect(try Sealer.shared.open(snapshot.entries[0].sealed) == "ERIKSSON")
    }
}
