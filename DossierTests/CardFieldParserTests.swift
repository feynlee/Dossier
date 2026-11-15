import CoreGraphics
import Testing
@testable import Dossier

/// Label-read facts on the made-up household's cards and notices, laid out the way OCR returned them.
struct CardFieldParserTests {
    static func page(_ rows: [(String, CGFloat, CGFloat)]) -> ReadPage {
        ReadPage(image: nil, lines: rows.map(\.0), boxes: rows.map { CGRect(x: $0.1, y: $0.2, width: 0.15, height: 0.02) }, barcodes: [])
    }

    @Test func readsALicencesDatesFromTheirLabels() {
        let page = Self.page([
            ("4d DLN", 0.30, 0.10), ("7812345", 0.30, 0.125),
            ("3 DOB", 0.30, 0.30), ("4b EXP", 0.50, 0.30), ("4a ISS", 0.70, 0.30),
            ("08/12/1990", 0.30, 0.325), ("08/12/2031", 0.50, 0.325), ("03/20/2023", 0.70, 0.325),
            ("16 HGT", 0.30, 0.40), ("18 EYES", 0.50, 0.40), ("5'-06\"", 0.30, 0.425), ("BRN", 0.50, 0.425),
        ])
        let found = CardFieldParser.fields(in: [page], kind: .driversLicense)
        #expect(found.first { $0.key == .dateOfBirth }?.value == "1990-08-12")
        #expect(found.first { $0.key == .expiryDate }?.value == "2031-08-12")
        #expect(found.first { $0.key == .issueDate }?.value == "2023-03-20")
        #expect(found.first { $0.key == .documentNumber }?.value == "7812345")
        let details = CardFieldParser.details(in: [page], kind: .driversLicense)
        #expect(details.contains { $0.label == "Eye colour" && $0.value == "BRN" })
        #expect(details.contains { $0.label == "Height" })
    }

    @Test func readsANoticesNumbers() {
        let page = Self.page([
            ("Receipt Number", 0.10, 0.20), ("MSC2190312345", 0.30, 0.20),
            ("Case Type", 0.10, 0.23), ("I-485, Application to Register Permanent Residence", 0.30, 0.23),
            ("A#", 0.10, 0.40), ("204-815-962", 0.30, 0.40),
        ])
        let found = CardFieldParser.fields(in: [page], kind: .uscisNotice)
        #expect(found.first { $0.key == .receiptNumber }?.value == "MSC2190312345")
        #expect(found.first { $0.key == .formType }?.value == "I-485")
        #expect(found.first { $0.key == .alienNumber }?.value == "204-815-962")
        let misread = Self.page([("Case Type", 0.10, 0.23), ("1-485 Application to Register Permanent Residence", 0.30, 0.23),
                                 ("Phone", 0.10, 0.30), ("1-800-375-5283", 0.30, 0.30)])
        #expect(CardFieldParser.fields(in: [misread], kind: .uscisNotice).first { $0.key == .formType }?.value == "I-485")
        #expect(KnowledgeText.words("1-485 notice") == ["i-485", "notice"])
    }

    @Test func readsTravelRows() {
        let page = Self.page([
            ("1", 0.05, 0.50), ("2025-03-22", 0.15, 0.50), ("Arrival", 0.35, 0.50), ("SEA", 0.55, 0.50),
            ("2", 0.05, 0.53), ("2025-03-02", 0.15, 0.53), ("Departure", 0.35, 0.53), ("SEA", 0.55, 0.53),
        ])
        let rows = TravelHistoryParser.rows(in: [page])
        #expect(rows.count == 2)
        // The first row out of place, as OCR put it right under the record number.
        let odd = ReadPage(image: nil, lines: ["Admission I-94 Record Number |", "2025-03-22", "Arrival", "SEA", "2025-03-02", "Departure", "SEA"],
                           boxes: [], barcodes: [])
        #expect(TravelHistoryParser.rows(in: [odd]).count == 2)
        #expect(rows.first?.date == "2025-03-22" && rows.first?.kind == "arrival" && rows.first?.port == "SEA")
    }
}
