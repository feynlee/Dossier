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
