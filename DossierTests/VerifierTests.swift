import CryptoKit
import Foundation
import Testing
@testable import Dossier

struct VerifierTests {
    let mrz = MRZParser.find(in: MRZParserTests.td3)

    @Test func verifiesFieldsThatMatchTheZone() throws {
        let results = Verifier.verify(
            [.init(key: .documentNumber, value: "L898902C3", page: 1), .init(key: .dateOfBirth, value: "1974-08-12", page: 1)],
            pages: [[]], mrz: mrz, license: nil
        )
        let number = try #require(results.first { $0.key == .documentNumber })
        #expect(number.status == .verified)
        #expect(number.check == .mrz)
        #expect(results.first { $0.key == .dateOfBirth }?.status == .verified)
    }

    @Test func doesNotCompareNationalityNamesWithZoneCodes() throws {
        let results = Verifier.verify([.init(key: .nationality, value: "UTOPIAN", page: 1)], pages: [["UTOPIAN"]], mrz: mrz, license: nil)
        let nationality = try #require(results.first { $0.key == .nationality })
        #expect(nationality.check == .pageText)
        #expect(nationality.alternate == nil)
    }

    @Test func sendsDisagreementsToReviewWithBothReadings() throws {
        let results = Verifier.verify([.init(key: .documentNumber, value: "L898902CB", page: 1)], pages: [[]], mrz: mrz, license: nil)
        let number = try #require(results.first { $0.key == .documentNumber })
        #expect(number.status == .needsReview)
        #expect(number.check == .conflict)
        #expect(number.alternate == "L898902C3")
    }

    @Test func addsZoneFactsTheModelMissed() {
        let results = Verifier.verify([], pages: [[]], mrz: mrz, license: nil)
        #expect(results.contains { $0.key == .expiryDate && $0.value == "2012-04-15" && $0.status == .verified })
    }

    @Test func ignoresAZoneWithFailedCheckDigits() {
        let broken = MRZParser.find(in: [MRZParserTests.td3[0], "L898902C86UTO7408122F1204159ZE184226B<<<<<10"])
        let results = Verifier.verify([.init(key: .documentNumber, value: "L898902C8", page: 1)], pages: [[]], mrz: broken, license: nil)
        #expect(results.first?.status == .needsReview)
        #expect(results.first?.check == .unchecked)
    }

    @Test func findsDatesInPageTextWhateverTheFormat() {
        let pages = [["Lease term begins January 1, 2023", "Tenant: Anna Eriksson"]]
        let results = Verifier.verify([.init(key: .leaseStartDate, value: "2023-01-01", page: 1)], pages: pages, mrz: nil, license: nil)
        #expect(results.first?.check == .pageText)
        #expect(results.first?.context == "Lease term begins January 1, 2023")
        #expect(results.first?.status == .verified)
    }

    @Test func sendsOnlyDoubtfulReadingsToReview() {
        let results = Verifier.verify(
            [
                .init(key: .address, value: "412 Alder St, Seattle", page: 1),
                .init(key: .placeOfBirth, value: "Stockholm", page: 1, isConfident: false),
                .init(key: .receiptNumber, value: "IOE0912345678", page: 1),
            ],
            pages: [["Tenant: Anna Eriksson"]], mrz: nil, license: nil
        )
        #expect(results.first { $0.key == .address }?.status == .verified, "confident names and addresses are accepted")
        #expect(results.first { $0.key == .address }?.check == .model)
        #expect(results.first { $0.key == .placeOfBirth }?.status == .needsReview, "the model said it wasn't sure")
        #expect(results.first { $0.key == .receiptNumber }?.status == .needsReview, "a number OCR can't find")
    }

    @Test func flagsLinesThatAlsoShowASensitiveNumber() {
        let facts = Verifier.verify(
            [.init(key: .surname, value: "ERIKSSON", page: 1), .init(key: .documentNumber, value: "PX7204821", page: 1)],
            pages: [["Name: ERIKSSON, ANNA MARIA · Passport: PX7204821"]], mrz: nil, license: nil
        )
        let surname = facts.first { $0.key == .surname }!
        #expect(Verifier.line(surname.context!, showsAnyOf: facts))
        #expect(!Verifier.line("Tenant: Anna Eriksson", showsAnyOf: facts))
    }

    @Test func keepsTheFirstReadingOfADuplicateKey() {
        let results = Verifier.verify(
            [.init(key: .surname, value: "Eriksson", page: 1), .init(key: .surname, value: "Erikson", page: 2)],
            pages: [[]], mrz: nil, license: nil
        )
        #expect(results.count == 1)
        #expect(results.first?.value == "Eriksson")
    }

    // Slips the on-device model made on the made-up household's documents.
    @Test func repairsTheModelsUsualSlips() {
        let pages = [["Surname ERIKSSON", "Given names ANNA MARIA", "3 DOB 4b EXP 4a ISS", "08/12/1990 08/12/2031 03/20/2023"]]
        let results = Verifier.verify([
            .init(key: .surname, value: "Eriksen", page: 1),
            .init(key: .dateOfBirth, value: "08/12/1990", page: 1),
            .init(key: .issueDate, value: "1990-08-12", page: 1),
            .init(key: .expiryDate, value: "2031-08-12", page: 1),
        ], pages: pages, mrz: nil, license: nil, kind: .driversLicense)
        #expect(results.first { $0.key == .surname }?.value == "Eriksson")
        #expect(results.first { $0.key == .dateOfBirth }?.value == "1990-08-12")
        #expect(!results.contains { $0.key == .issueDate })
    }

    @Test func swapsIssueAndExpiryWhenBackwards() {
        let results = Verifier.verify([
            .init(key: .issueDate, value: "2026-08-12", page: 1), .init(key: .expiryDate, value: "2020-09-01", page: 1),
        ], pages: [[]], mrz: nil, license: nil)
        #expect(results.first { $0.key == .issueDate }?.value == "2020-09-01")
        #expect(results.first { $0.key == .expiryDate }?.value == "2026-08-12")
    }
}

struct SealerTests {
    @Test func roundTripsAndRejectsTampering() throws {
        let key = SymmetricKey(size: .bits256)
        var sealed = try Sealer.seal(Data("A123456789".utf8), with: key)
        #expect(try Sealer.open(sealed, with: key) == Data("A123456789".utf8))
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) { try Sealer.open(sealed, with: key) }
    }

    @Test func formatsDatesUnambiguously() {
        #expect(SimpleDate(iso: "2029-03-14")?.display == "14 Mar 2029")
        #expect(SimpleDate(iso: "2029-13-01") == nil)
    }
}

struct AppLockPolicyTests {
    @Test func locksOnlyAfterTheChosenTimeInTheBackground() {
        #expect(!AppLockPolicy.shouldLock(afterBackground: .seconds(30), timeout: 60), "a quick switch to Safari")
        #expect(AppLockPolicy.shouldLock(afterBackground: .seconds(61), timeout: 60))
        #expect(AppLockPolicy.shouldLock(afterBackground: .milliseconds(1), timeout: 0), "Immediately")
        #expect(AppLockPolicy.label(for: 300) == "After 5 minutes")
        #expect(AppLockPolicy.timeoutChoices.contains(AppLockPolicy.defaultTimeout))
    }
}

struct DocumentContentsTests {
    let pages = [[
        "INTERNATIONAL CERTIFICATE OF VACCINATION",
        "Yellow fever 12 JUL 2018 Lot AB123 Travel clinic Seattle",
        "MMR 02/04/2019 Lot MM55",
    ]]

    @Test func entriesWithEveryNumberOnThePageAreVerified() throws {
        let dose = try #require(Verifier.verifyEntry("2018-07-12 · Lot AB123 · Travel clinic Seattle", isConfident: true, page: 1, pages: pages))
        #expect(dose.status == .verified)
        #expect(dose.check == .pageText)
        #expect(dose.value == "2018-07-12 · Lot AB123 · Travel clinic Seattle")
    }

    @Test func entriesWithANumberNotOnThePageNeedALook() throws {
        let wrongLot = try #require(Verifier.verifyEntry("2018-07-12 · Lot AB128", isConfident: true, page: 1, pages: pages))
        #expect(wrongLot.status == .needsReview)
        let unsure = try #require(Verifier.verifyEntry("Negative", isConfident: false, page: 1, pages: pages))
        #expect(unsure.status == .needsReview)
        let words = try #require(Verifier.verifyEntry("Normal", isConfident: true, page: 1, pages: pages))
        #expect(words.status == .verified)
        #expect(Verifier.verifyEntry("  ", isConfident: true, page: 1, pages: pages) == nil)
    }

    @Test func entriesAreIdentifiedBySectionAndLabel() {
        #expect(Fact.entryID(section: "Vaccinations", label: "MMR · dose 1") == "entry|vaccinations|mmr · dose 1")
        #expect(Fact.entryID(section: "Vaccinations", label: "MMR · dose 1") != Fact.entryID(section: "Boosters", label: "MMR · dose 1"))
    }

    @Test func instructionsAskForEverythingTheDocumentRecords() {
        let instructions = DocumentExtractor.instructions(for: DetailRequest())
        #expect(instructions.contains("contents"))
        #expect(instructions.contains("vaccination"))
        #expect(instructions.contains("every table row"))
        #expect(instructions.contains("another form might ask for"))
    }
}
