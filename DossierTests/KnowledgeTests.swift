import Foundation
import Testing
@testable import Dossier

/// The knowledge layer on the made-up household, read exactly as the answer key says: each of the conflicts
/// the samples were built with is settled the way a careful person would.
struct KnowledgeTests {
    let knowledge: Knowledge

    init() throws {
        knowledge = KnowledgeBuilder.build(try HouseholdFixture.groundTruth(), today: HouseholdFixture.today)
    }

    func topic(_ person: String, _ suffix: String) throws -> KnowledgeTopic {
        try #require(knowledge.topics.first { $0.person == person && $0.id.hasSuffix(suffix) }, "no topic \(person) \(suffix)")
    }

    @Test func findsThePeopleAndHowTheyRelate() {
        #expect(knowledge.owner == "Anna")
        #expect(knowledge.person("David")?.relation == .spouse)
        #expect(knowledge.person("Emma")?.relation == .child)
    }

    @Test func currentPassportIsTheOneInForce() throws {
        let number = try topic("Anna", "passport|documentNumber")
        #expect(number.current?.value.hint == "4821")
        #expect(number.others.first?.value.hint == "8457")
        #expect(try topic("Anna", "passport|expiryDate").current?.value.text == "2029-03-14")
    }

    @Test func currentAddressIsTheNewLeaseNotTheLicence() throws {
        let address = try topic("Anna", "|state|address")
        #expect(address.current?.value.text?.contains("1720 NW Lovejoy") == true)
        #expect(address.note?.contains("88") == true)
    }

    @Test func addendumEndsTheOldLeaseEarly() throws {
        let end = try topic("Anna", "lease|leaseEndDate")
        // The current lease is the Lovejoy one…
        #expect(end.current?.value.text == "2027-06-30")
        // …and the Pine Ave lease's end was moved to the addendum's date.
        let pine = end.others.first { $0.source.title.contains("Pine") }
        #expect(pine?.validUntil == SimpleDate(year: 2026, month: 6, day: 30))
    }

    @Test func birthDateTypoIsOutvoted() throws {
        let birth = try topic("Anna", "identity|dateOfBirth")
        #expect(birth.current?.value.text == "1990-08-12")
        #expect(!birth.isConflict)
        #expect(birth.note?.contains("1990-08-21") == true)
    }

    @Test func marriedNameIsAnotherNameNotAConflict() throws {
        let surname = try topic("Anna", "identity|surname")
        #expect(surname.current?.value.text == "ERIKSSON")
        #expect(!surname.isConflict)
        #expect(try topic("Anna", "identity|otherNames").current?.value.text?.contains("ERIKSSON-CHEN") == true)
        #expect(try topic("Anna", "identity|givenNames").current?.value.text == "ANNA MARIA")
    }

    @Test func placeOfBirthCityAndCountryDontConflict() throws {
        let place = try topic("Anna", "identity|placeOfBirth")
        #expect(place.current?.value.text == "LUMEN CITY")
        #expect(!place.isConflict)
    }

    @Test func newestPhoneWins() throws {
        let phone = try #require(knowledge.topics.first { $0.person == "Anna" && $0.name == "Phone" })
        #expect(phone.current?.value.text == "(503) 555-0188")
    }

    @Test func currentLicenceIsOregon() throws {
        #expect(try topic("Anna", "licence|documentNumber").current?.value.hint == "2345")
        #expect(try topic("Anna", "licence|expiryDate").current?.value.text == "2031-08-12")
    }

    @Test func lastTetanusShotComesFromTheMedicalExam() throws {
        let tetanus = try topic("Anna", "vaccine|tetanus")
        #expect(tetanus.current?.date == SimpleDate(year: 2020, month: 2, day: 20))
        #expect(tetanus.claims.count == 2)
    }

    @Test func immigrationStatusIsTheGreenCard() throws {
        let status = try topic("Anna", "|state|status")
        #expect(status.current?.value.text == "Permanent resident (E21)")
        #expect(status.others.count == 2)
    }

    @Test func emmaHasFourDTaPDoses() throws {
        let answer = RuleAnswerer.answer(KnowledgeQuestion("How many DTaP doses has Emma had?", knowledge: knowledge), in: knowledge)
        #expect(answer?.text.contains("4") == true)
    }

    @Test func rulesAnswerCommonQuestions() throws {
        func ask(_ text: String) -> String { RuleAnswerer.answer(KnowledgeQuestion(text, knowledge: knowledge), in: knowledge)?.text ?? "" }
        #expect(ask("When does my passport expire?").contains("2029"))
        #expect(ask("Where did I live in 2021?").contains("412 Alder"))
        #expect(ask("When was my last tetanus shot?").contains("2020"))
        #expect(ask("When does David's passport expire?").contains("2027"))
        #expect(ask("When was I born?").contains("1990"))
    }

    @Test func birthDateQuestionFindsTheBirthDate() {
        let question = KnowledgeQuestion("When was I born?", knowledge: knowledge)
        let matches = KnowledgeSearch.search(question, in: knowledge, limit: 5)
        let listing = matches.map { "\($0.topic.id) \(String(format: "%.2f", $0.score)) covers=\(RuleAnswerer.covers($0.topic, question)) value=\($0.topic.current?.value.text ?? "nil")" }
            .joined(separator: " | ")
        let answer = RuleAnswerer.answer(question, in: knowledge)?.text ?? "nil"
        #expect(answer.contains("1990"), "words=\(question.words) people=\(question.people) answer=\(answer) matches: \(listing)")
    }

    // Questions the Siri test got wrong, and why.
    @Test func answersFromTheDocumentTheQuestionNames() throws {
        func ask(_ text: String) -> String { RuleAnswerer.answer(KnowledgeQuestion(text, knowledge: knowledge), in: knowledge)?.text ?? "" }
        // Two homes in 2024 for the household; the one that covers most of the year.
        #expect(ask("Where did we live in 2024?").contains("88 Pine"))
        // The old lease's rent, not today's lease.
        #expect(ask("What was my rent at Pine Ave?").contains("2,480"))
        // The termination addendum moved the end forward.
        #expect(ask("When did we move out of Pine Ave?").contains("30 June 2026"))
    }

    @Test func rulesLeaveQuestionsTheyDoNotCoverToTheModel() {
        let question = KnowledgeQuestion("When was my I-485 approved?", knowledge: knowledge)
        let answer = RuleAnswerer.answer(question, in: knowledge)
        #expect(answer.map { !$0.text.contains("born") } ?? true)
    }

    @Test func modelAnswersMustRestOnTheirFacts() {
        let facts = ["F1 · Anna · Lease · Rent: $2,480.00 (Lease for 88 Pine Ave, 1 July 2023 to 30 June 2026)"]
        #expect(ModelAnswerer.isGrounded("Your rent at Pine Ave was $2,480 a month.", in: facts))
        #expect(!ModelAnswerer.isGrounded("Your rent was $1,200.", in: facts))
        #expect(!ModelAnswerer.isGrounded("Your lease ended on 30 April 2026.", in: facts))
        #expect(ModelAnswerer.isGrounded("Your lease ends on 30 June 2026.", in: facts))
        let people = ["People: Anna (the person asking), David (spouse), Emma (child)."]
        #expect(!ModelAnswerer.isGrounded("Linda Chen, born Wu.", in: people))
        #expect(ModelAnswerer.isGrounded("Your husband is David.", in: people))
        #expect(ModelAnswerer.isGrounded("Emma's birth certificate number ends in 7182.",
                                         in: people + ["F1 · Emma · Birth certificate number: [hidden number ending 7182] (Birth certificate)"]))
    }

    @Test func modelAnswersAboutARelativeMustCiteThatRelative() throws {
        let question = KnowledgeQuestion("What's my father's name?", knowledge: knowledge)
        let father = try #require(knowledge.topics.first { $0.person == "Anna" && $0.id.contains("|detail|father|") })
        #expect(ModelAnswerer.fitsRelation([father], question))
        let spouse = knowledge.topics.filter { $0.person == "David" }
        #expect(!ModelAnswerer.fitsRelation(spouse, question))
        let other = KnowledgeQuestion("When does my passport expire?", knowledge: knowledge)
        #expect(ModelAnswerer.fitsRelation(spouse, other))
    }

    @Test func daysAbroadCountsWholeDaysAway() {
        let trip = KnowledgeTrip(person: "Anna", departure: SimpleDate(year: 2024, month: 8, day: 9)!, arrival: SimpleDate(year: 2024, month: 8, day: 25)!,
                                 departurePort: "SEA", arrivalPort: "SEA")
        #expect(trip.daysAbroad(in: 2024, today: HouseholdFixture.today) == 15)
        #expect(trip.daysAbroad(in: 2023, today: HouseholdFixture.today) == 0)
    }

    @Test func readsDatesInEverySpelling() {
        let expected = SimpleDate(year: 2020, month: 2, day: 20)
        for text in ["2020-02-20", "02/20/2020", "20 FEB 2020", "February 20, 2020", "Td · 2020-02-20 · Lot X"] {
            #expect(KnowledgeText.date(text) == expected, "\(text)")
        }
    }
}
