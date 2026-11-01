import CoreGraphics
import Foundation
import Testing
@testable import Dossier

/// "What's my blood type?": the made-up health summary in SampleDocuments/Health, read the ways the app can
/// save it, asked the ways people ask Siri.
struct HealthRecordTests {
    static let bloodType = "O Rh positive (O+)"

    /// The health summary as the app saves it: a section of contents, or a holder's detail (no section).
    static func healthRecord(person: String?, asDetail: Bool = false) -> KnowledgeDocument {
        let rows: [(String, String, String)] = [
            ("Patient", "Primary care physician", "Dr. Tomas Lind, MD"),
            ("Vitals and blood type", "Blood type", bloodType),
            ("Vitals and blood type", "Height", "5 ft 6 in (168 cm)"),
            ("Vitals and blood type", "Blood pressure", "116/74 mmHg"),
            ("Allergies", "Penicillin", "Hives · Moderate"),
            ("Allergies", "Peanuts", "Throat swelling · Severe"),
            ("Emergency contact", "Emergency contact", "David Lee Chen (spouse)"),
        ]
        let entries = rows.map { section, label, value in
            KnowledgeEntry(section: asDetail && label == "Blood type" ? nil : section, label: label, value: .plain(value))
        }
        return KnowledgeDocument(id: "health-summary", kind: .other, title: "Patient health summary", person: person,
                                 fields: [.issueDate: .plain("2026-09-14")], entries: entries)
    }

    func ask(_ question: String, _ documents: [KnowledgeDocument]) -> String? {
        let knowledge = KnowledgeBuilder.build(documents, today: HouseholdFixture.today)
        return RuleAnswerer.answer(KnowledgeQuestion(question, knowledge: knowledge), in: knowledge)?.text
    }

    @Test(arguments: ["What's my blood type?", "Can you find my blood type in Dossier?", "What's my blood group?",
                      "Find my blood type", "what is my blood type"])
    func answersBloodTypeInAFullVault(question: String) throws {
        let documents = try HouseholdFixture.groundTruth() + [Self.healthRecord(person: "Anna")]
        let answer = try #require(ask(question, documents), "no rule answer")
        #expect(answer.contains("O Rh positive"), "\(answer)")
    }

    @Test func answersBloodTypeReadAsADetail() throws {
        let documents = try HouseholdFixture.groundTruth() + [Self.healthRecord(person: "Anna", asDetail: true)]
        let answer = try #require(ask("What's my blood type?", documents))
        #expect(answer.contains("O Rh positive"), "\(answer)")
    }

    /// Before: with no document placed in the library yet, nobody was the owner and "my" matched nothing.
    @Test func answersBeforeTheLibraryIsOrganized() throws {
        let answer = try #require(ask("What's my blood type?", [Self.healthRecord(person: nil)]))
        #expect(answer.contains("O Rh positive"), "\(answer)")
    }

    /// Before: a health record filed under another first name than the rest of your documents was never searched.
    @Test func answersWhenTheRecordIsFiledUnderAnotherName() throws {
        var others = try HouseholdFixture.groundTruth().filter { $0.person == "Anna" }
        others = others.map { var document = $0; document.person = "Li"; return document }
        let answer = try #require(ask("What's my blood type?", others + [Self.healthRecord(person: "Ziyue")]))
        #expect(answer.contains("O Rh positive"), "\(answer)")
    }

    /// Before: Siri was offered only the first 60 facts, and in a full vault the blood type wasn't one of them.
    @Test func siriCanNameTheBloodType() throws {
        let knowledge = KnowledgeBuilder.build(try HouseholdFixture.groundTruth() + [Self.healthRecord(person: "Anna")], today: HouseholdFixture.today)
        let suggested = KnowledgeEntityQuery.suggested(knowledge)
        let blood = try #require(suggested.first { $0.name.hasSuffix("Blood type") })
        #expect(blood.person == "Anna")
        #expect(suggested.prefix(while: { $0.person == "Anna" }).contains { $0.id == blood.id })
    }
}

/// The health summary's "label   value" rows, as Vision lays them out (top-left origin).
struct LabelValueParserTests {
    static func page() -> ReadPage {
        // (text, x, y): labels at x 0.09, values at x 0.37, as on the generated PDF.
        let boxes: [(String, CGFloat, CGFloat)] = [
            ("PATIENT HEALTH SUMMARY", 0.09, 0.08),
            ("Patient", 0.09, 0.14),
            ("Patient name", 0.09, 0.17), ("Anna Maria Eriksson", 0.37, 0.17),
            ("Primary care physician", 0.09, 0.20), ("Dr. Tomas Lind, MD", 0.37, 0.20),
            ("Vitals and blood type", 0.09, 0.25),
            ("Blood type", 0.09, 0.28), ("O Rh positive (O+)", 0.37, 0.28),
            ("Blood pressure", 0.09, 0.31), ("116/74 mmHg", 0.37, 0.31),
            ("Allergies", 0.09, 0.36),
            ("Allergen", 0.09, 0.39), ("Reaction", 0.39, 0.39), ("Severity", 0.68, 0.39),
            ("Penicillin", 0.09, 0.42), ("Hives", 0.39, 0.42), ("Moderate", 0.68, 0.42),
            ("Emergency contact", 0.09, 0.47),
            ("Emergency contact", 0.09, 0.50), ("David Lee Chen (spouse)", 0.37, 0.50),
        ]
        return ReadPage(image: nil, lines: boxes.map(\.0),
                        boxes: boxes.map { CGRect(x: $0.1, y: $0.2, width: min(0.25, CGFloat($0.0.count) * 0.012), height: 0.018) }, barcodes: [])
    }

    @Test func readsLabelledRowsUnderTheirHeadings() {
        let rows = LabelValueParser.rows(in: [Self.page()])
        #expect(rows.contains(.init(section: "Vitals and blood type", label: "Blood type", value: "O Rh positive (O+)", page: 1)))
        #expect(rows.contains(.init(section: "Patient", label: "Primary care physician", value: "Dr. Tomas Lind, MD", page: 1)))
        #expect(rows.contains(.init(section: "Emergency contact", label: "Emergency contact", value: "David Lee Chen (spouse)", page: 1)))
        // A table: its header names the columns and isn't an entry.
        #expect(rows.contains(.init(section: "Allergies", label: "Penicillin", value: "Hives · Moderate", page: 1)))
        #expect(!rows.contains { $0.label == "Allergen" })
    }

    @Test func addsOnlyWhatTheModelMissed() {
        let reading = DocumentReading(
            kind: DocumentKind.other.rawValue, title: "Patient health summary", fields: [],
            contents: [ReadEntry(section: "Vitals", label: "Blood pressure", value: "116/74 mmHg", page: 1, confidence: "high", isNumber: "no")],
            details: [], travel: []
        )
        let read = LabelValueParser.apply(to: reading, pages: [Self.page()])
        #expect(read.contents.filter { $0.label == "Blood pressure" }.count == 1)
        #expect(read.contents.contains { $0.label == "Blood type" && $0.value == "O Rh positive (O+)" })
        var passport = reading
        passport.kind = DocumentKind.passport.rawValue
        #expect(LabelValueParser.apply(to: passport, pages: [Self.page()]).contents.count == 1)
    }
}
