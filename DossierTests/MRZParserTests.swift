import CoreGraphics
import Testing
@testable import Dossier

/// Uses the specimen zones from ICAO Doc 9303, whose check digits are known to be valid.
struct MRZParserTests {
    static let td3 = [
        "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
        "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
    ]
    static let td1 = [
        "I<UTOD231458907<<<<<<<<<<<<<<<",
        "7408122F1204159UTO<<<<<<<<<<<6",
        "ERIKSSON<<ANNA<MARIA<<<<<<<<<<",
    ]

    @Test func checkDigitsMatchTheSpecification() {
        #expect(MRZParser.checkDigit("L898902C3") == 6)
        #expect(MRZParser.checkDigit("740812") == 2)
        #expect(MRZParser.checkDigit("120415") == 9)
        #expect(MRZParser.checkDigit("ZE184226B<<<<<") == 1)
    }

    @Test func parsesPassportZone() throws {
        let result = try #require(MRZParser.find(in: Self.td3))
        #expect(result.format == .td3)
        #expect(result.isValid, "failed: \(result.failedChecks)")
        #expect(result.documentNumber == "L898902C3")
        #expect(result.issuingCountry == "UTO")
        #expect(result.surname == "ERIKSSON")
        #expect(result.givenNames == "ANNA MARIA")
        #expect(result.dateOfBirth == SimpleDate(year: 1974, month: 8, day: 12))
        #expect(result.expiryDate == SimpleDate(year: 2012, month: 4, day: 15))
        #expect(result.sex == "F")
    }

    @Test func parsesCardZone() throws {
        let result = try #require(MRZParser.find(in: Self.td1))
        #expect(result.format == .td1)
        #expect(result.isValid, "failed: \(result.failedChecks)")
        #expect(result.documentNumber == "D23145890")
        #expect(result.surname == "ERIKSSON")
        #expect(result.givenNames == "ANNA MARIA")
    }

    @Test func findsZoneAmongOtherTextWithOCRNoise() throws {
        let lines = ["PASSPORT", "Surname / Nom", "ERIKSSON", "P<UTOERIKSSON«ANNA<MARIA<<<<<<<<<<<<<<<<<<<", "L898902C36 UTO7408122F1204159ZE184226B<<<<<10"]
        let result = try #require(MRZParser.find(in: lines))
        #expect(result.isValid)
        #expect(result.documentNumber == "L898902C3")
    }

    @Test func correctsLettersReadInNumericFields() throws {
        // OCR read the zero in the birth date as the letter O.
        let lines = [Self.td3[0], "L898902C36UTO74O8122F1204159ZE184226B<<<<<10"]
        let result = try #require(MRZParser.find(in: lines))
        #expect(result.isValid)
        #expect(result.dateOfBirth == SimpleDate(year: 1974, month: 8, day: 12))
    }

    @Test func flagsAMisreadDocumentNumber() throws {
        let lines = [Self.td3[0], "L898902C86UTO7408122F1204159ZE184226B<<<<<10"]
        let result = try #require(MRZParser.find(in: lines))
        #expect(!result.isValid)
        #expect(result.failedChecks.contains("document number"))
    }
    // What Vision actually read off the made-up household's green card and passport photo: each zone line split
    // into pieces at its runs of `<`, with some filler lost.
    @Test func joinsACardZoneSplitIntoPieces() throws {
        let lines = ["C1USASRC219045<67896<<<<", "<<<", "9008124F3103016UTO<<", "<<6", "ERIKSSON<<ANNA<MARIA<<"]
        let result = try #require(MRZParser.find(in: lines))
        #expect(result.isValid)
        #expect(result.documentNumber == "SRC2190456789")
        #expect(result.dateOfBirth == SimpleDate(year: 1990, month: 8, day: 12))
        #expect(result.surname == "ERIKSSON")
    }

    @Test func joinsAPassportZoneByRow() throws {
        let lines = ["<<<<<<<<", "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<", "<<<<<00", "PX72048212UT09008124F2903149<<<"]
        let boxes = [CGRect(x: 0.8, y: 0.80, width: 0.15, height: 0.03), CGRect(x: 0.05, y: 0.805, width: 0.7, height: 0.03),
                     CGRect(x: 0.82, y: 0.85, width: 0.13, height: 0.03), CGRect(x: 0.05, y: 0.852, width: 0.6, height: 0.03)]
        let result = try #require(MRZParser.find(in: lines, boxes: boxes))
        #expect(result.isValid)
        #expect(result.documentNumber == "PX7204821")
        #expect(result.nationality == "UTO")
        #expect(result.expiryDate == SimpleDate(year: 2029, month: 3, day: 14))
    }

}

struct AAMVAParserTests {
    static let payload = "@\n\u{1e}\rANSI 636014090002DL00410278ZC03190008DLDAQD1234567\nDCSSAMPLE\nDACANNA\nDADMARIA\nDBB08121974\nDBA01302027\nDBD01302023\nDAG88 PINE AVE\nDAIPORTLAND\nDAJOR\nDAK972050000\nDCGUSA\n"

    @Test func parsesLicenceFields() throws {
        let record = try #require(AAMVAParser.parse(Self.payload))
        #expect(record.licenseNumber == "D1234567")
        #expect(record.surname == "SAMPLE")
        #expect(record.givenNames == "ANNA MARIA")
        #expect(record.dateOfBirth == SimpleDate(year: 1974, month: 8, day: 12))
        #expect(record.expiryDate == SimpleDate(year: 2027, month: 1, day: 30))
        #expect(record.address == "88 PINE AVE, PORTLAND, OR 97205")
    }

    @Test func readsCanadianDateOrder() {
        #expect(AAMVAParser.date("20270130", country: "CAN") == SimpleDate(year: 2027, month: 1, day: 30))
    }

    @Test func rejectsNonAAMVAPayloads() {
        #expect(AAMVAParser.parse("https://example.com") == nil)
    }
}
