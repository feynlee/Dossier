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
        #expect(results.first?.status == .needsReview)
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
