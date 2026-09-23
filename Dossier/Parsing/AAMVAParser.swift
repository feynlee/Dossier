import Foundation

/// The fields Dossier uses from the PDF417 barcode on the back of a US or Canadian driver's licence.
nonisolated struct AAMVARecord: Equatable, Sendable {
    var licenseNumber: String?
    var surname: String?
    var givenNames: String?
    var dateOfBirth: SimpleDate?
    var issueDate: SimpleDate?
    var expiryDate: SimpleDate?
    var street: String?
    var city: String?
    var state: String?
    var postalCode: String?
    var country: String?

    var address: String? {
        guard let street else { return nil }
        let locality = [city, [state, postalCode].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return locality.isEmpty ? street : "\(street), \(locality)"
    }
}

/// Parses the AAMVA DL/ID card design standard payload. Vision decodes the barcode; this turns its text
/// into fields that can check what Private Cloud Compute read off the front of the card.
nonisolated enum AAMVAParser {
    static func parse(_ payload: String) -> AAMVARecord? {
        guard payload.contains("ANSI") || payload.contains("AAMVA") else { return nil }

        var elements: [String: String] = [:]
        let lines = payload.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{1e}"))
        for rawLine in lines {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            // The first element of a subfile follows its type, e.g. "DLDAQ123456".
            if let range = line.range(of: "DLDAQ") ?? line.range(of: "IDDAQ") {
                line = line[line.index(range.lowerBound, offsetBy: 2)...]
            }
            guard line.count > 3, line.first == "D" else { continue }
            let code = String(line.prefix(3))
            guard code.allSatisfy({ $0.isUppercase && $0.isASCII }), elements[code] == nil else { continue }
            let value = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { elements[code] = value }
        }
        guard !elements.isEmpty else { return nil }

        let country = elements["DCG"]
        let givenNames = [elements["DAC"] ?? elements["DCT"], elements["DAD"]]
            .compactMap { $0 }
            .filter { !["NONE", "UNAVL"].contains($0.uppercased()) }
            .joined(separator: " ")

        return AAMVARecord(
            licenseNumber: elements["DAQ"],
            surname: elements["DCS"] ?? elements["DAB"],
            givenNames: givenNames.isEmpty ? nil : givenNames,
            dateOfBirth: date(elements["DBB"], country: country),
            issueDate: date(elements["DBD"], country: country),
            expiryDate: date(elements["DBA"], country: country),
            street: [elements["DAG"], elements["DAH"]].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            city: elements["DAI"],
            state: elements["DAJ"],
            postalCode: elements["DAK"].map { String($0.prefix(5)) },
            country: country
        )
    }

    /// US cards print `MMDDCCYY`; Canadian cards print `CCYYMMDD`.
    static func date(_ value: String?, country: String?) -> SimpleDate? {
        guard let value, value.count == 8, value.allSatisfy(\.isNumber) else { return nil }
        let characters = Array(value)
        let number = { (range: Range<Int>) in Int(String(characters[range])) ?? 0 }
        let leadingYear = number(0..<4)
        if country == "CAN" || leadingYear > 1800 {
            return SimpleDate(year: leadingYear, month: number(4..<6), day: number(6..<8))
        }
        return SimpleDate(year: number(4..<8), month: number(0..<2), day: number(2..<4))
    }
}

nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
