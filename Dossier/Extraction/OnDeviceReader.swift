import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import os

/// Reads a document with the on-device model in small steps. Its context is 4,096 tokens for the
/// instructions, the schema, the page and the answer together, and the one-shot reading PCC does overflows it
/// on any document with a table (seen in testing: 15 of 34 documents). So the on-device model first reads what
/// the document is and its standard facts, then reads the rest a part at a time, each part in a fresh session.
nonisolated struct OnDeviceReader {
    var model: SystemLanguageModel
    var request: DetailRequest
    private let logger = Logger(subsystem: "liziyue.Dossier", category: "Extraction")

    init(model: SystemLanguageModel, request: DetailRequest) {
        self.model = model
        self.request = request
    }

    /// The most text one part holds. With the instructions and schema that leaves about half the context for
    /// the answer.
    static let partLimit = 1_800
    /// Parts read per document; the rest of a very long document is left out.
    static let maxParts = 14

    func read(_ pages: [ReadPage]) async throws -> DocumentReading {
        let facts = try await readFacts(pages)
        let kind = DocumentKind(rawValue: facts.kind) ?? .other
        var contents: [ReadEntry] = []
        var details: [ReadDetail] = []
        var travel: [ReadTravelEvent] = []
        var seen = Set<String>()
        let known = facts.fields.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        for part in Self.parts(of: pages).prefix(Self.maxParts) {
            if kind == .i94 {
                travel += (try? await readTravel(part.text)) ?? []
            }
            for read in await readPart(part, facts: facts, known: known) {
                for entry in read.contents where !entry.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    let key = [entry.section, entry.label, entry.value].joined(separator: "|").lowercased()
                    guard seen.insert(key).inserted else { continue }
                    contents.append(ReadEntry(section: entry.section, label: entry.label, value: entry.value, page: part.page, confidence: "high", isNumber: entry.isNumber))
                }
                for detail in read.details where !detail.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    let key = ["d", detail.person, detail.personName, detail.label, detail.value].joined(separator: "|").lowercased()
                    guard seen.insert(key).inserted else { continue }
                    details.append(ReadDetail(person: detail.person, personName: detail.personName, label: detail.label, value: detail.value,
                                              page: part.page, confidence: "high", isNumber: detail.isNumber))
                }
            }
        }
        let fields = facts.fields.map { field in
            ReadField(key: field.key, value: field.value, page: Self.page(of: field.value, in: pages), confidence: field.confidence)
        }
        return DocumentReading(kind: facts.kind, title: facts.title, fields: fields, contents: contents,
                               details: request.isEmpty ? [] : details, travel: travel)
    }

    // MARK: Steps

    private func readFacts(_ pages: [ReadPage]) async throws -> DeviceFacts {
        let text = Self.text(of: pages)
        var lastError: Error?
        for (limit, image) in [(3_000, true), (3_000, false), (1_500, false)] {
            let session = LanguageModelSession(model: model, instructions: Self.factsInstructions)
            let attach = image && model.capabilities.contains(.vision) ? pages.first?.image : nil
            let prompt = Prompt {
                if let attach {
                    "Page 1 of the document:"
                    Attachment(attach, orientation: .up).label("page 1")
                    "OCR text:"
                } else {
                    "OCR text of the document:"
                }
                String(text.prefix(limit))
            }
            do {
                return try await session.respond(to: prompt, generating: DeviceFacts.self, options: GenerationOptions(samplingMode: .greedy)).content
            } catch {
                lastError = error
                guard DocumentExtractor.isContextOverflow(error) else { break }
                logger.notice("On-device facts didn't fit with \(limit) characters; trying with less")
            }
        }
        throw ExtractorError.failed(lastError.map { String(describing: $0) } ?? "The document couldn’t be read.")
    }

    /// One part; when its answer doesn't fit, its two halves.
    private func readPart(_ part: Part, facts: DeviceFacts, known: String) async -> [DevicePart] {
        let instructions = Self.partInstructions(kind: facts.kind, title: facts.title, known: known, request: request)
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let prompt = "Part of the document (page \(part.page)):\n\(part.text)"
            return [try await session.respond(to: prompt, generating: DevicePart.self, options: GenerationOptions(samplingMode: .greedy)).content]
        } catch let error where DocumentExtractor.isContextOverflow(error) && part.text.count > 400 {
            let lines = part.text.components(separatedBy: "\n")
            let middle = lines.count / 2
            guard middle > 0 else { return [] }
            let first = Part(page: part.page, text: lines[..<middle].joined(separator: "\n"))
            let second = Part(page: part.page, text: lines[middle...].joined(separator: "\n"))
            return await readPart(first, facts: facts, known: known) + readPart(second, facts: facts, known: known)
        } catch {
            logger.error("On-device part of page \(part.page) failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func readTravel(_ text: String) async throws -> [ReadTravelEvent] {
        let session = LanguageModelSession(model: model, instructions: "You copy rows from an I-94 travel history. Report every arrival and departure row in the text, with its date as YYYY-MM-DD and its port as printed. Only rows that are printed.")
        return try await session.respond(to: text, generating: DeviceTravel.self, options: GenerationOptions(samplingMode: .greedy)).content.travel
    }

    // MARK: Text

    struct Part {
        var page: Int
        var text: String
    }

    static func text(of pages: [ReadPage]) -> String {
        pages.enumerated().map { index, page in "--- Page \(index + 1) ---\n" + page.lines.joined(separator: "\n") }.joined(separator: "\n")
    }

    /// Each page's lines in runs of at most `partLimit` characters.
    static func parts(of pages: [ReadPage]) -> [Part] {
        var parts: [Part] = []
        for (index, page) in pages.enumerated() {
            var current = ""
            for line in page.lines {
                if current.count + line.count + 1 > partLimit, !current.isEmpty {
                    parts.append(Part(page: index + 1, text: current))
                    current = ""
                }
                current += (current.isEmpty ? "" : "\n") + line
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(Part(page: index + 1, text: current)) }
        }
        return parts
    }

    /// The page a value is printed on, for the verifier; page 1 when it can't be found.
    static func page(of value: String, in pages: [ReadPage]) -> Int {
        let needle = value.lowercased().filter { $0.isLetter || $0.isNumber }
        guard needle.count >= 3 else { return 1 }
        for (index, page) in pages.enumerated() where page.lines.joined().lowercased().filter({ $0.isLetter || $0.isNumber }).contains(needle) {
            return index + 1
        }
        return 1
    }

    // MARK: Instructions

    static let factsInstructions = """
        You read a personal document for its owner. Say what kind of document it is, give it a short title, \
        and report the holder's standard facts for its kind:
        - passport: surname, givenNames, dateOfBirth, placeOfBirth, sex, nationality, documentNumber, issueDate, expiryDate, issuingAuthority
        - greenCard: surname, givenNames, dateOfBirth, placeOfBirth, sex, alienNumber, uscisCategory, residentSince, documentNumber, expiryDate
        - employmentAuthorization: surname, givenNames, dateOfBirth, placeOfBirth, sex, alienNumber, uscisCategory, documentNumber, validFrom, validUntil
        - visa: surname, givenNames, dateOfBirth, nationality, documentNumber, uscisCategory, issueDate, expiryDate
        - driversLicense or stateID: surname, givenNames, dateOfBirth, sex, address, documentNumber, licenseClass, issueDate, expiryDate
        - lease: address, leaseStartDate, leaseEndDate
        - uscisNotice: surname, givenNames, dateOfBirth, alienNumber, formType, receiptNumber, noticeDate, uscisCategory, validFrom, validUntil
        - i94: surname, givenNames, dateOfBirth, i94Number, classOfAdmission, admitUntil, documentNumber
        - other: surname, givenNames, dateOfBirth, address, documentNumber, issueDate, expiryDate, and formType for a numbered form
        Only the holder's facts, only what is printed; never guess. Copy numbers exactly. Dates as YYYY-MM-DD; \
        US documents write dates month first. For a USCIS notice, formType is the form the notice is about \
        (such as I-485), not I-797.
        """

    static func partInstructions(kind: String, title: String, known: String, request: DetailRequest) -> String {
        var text = """
            You copy what a personal document records, one part at a time. This part is from: \(title) (\(kind)). \
            Already read, so leave out: \(known.isEmpty ? "nothing" : known).
            In contents, report every filled-in field, table row and result in this part, in reading order, \
            labelled with the document's own words and grouped by its own section headings: each test and \
            result, each vaccine dose (date, product, lot), each tax box, a lease's rent, deposit and terms, and \
            the people it names in a role (doctor, landlord, employer). For a table row, join its columns with \
            " · ". Leave out instructions, legal fine print and blank fields.
            """
        if request.isEmpty {
            text += "\nLeave details empty."
        } else {
            text += "\nIn details, report details about the holder or their family that are useful for forms, such as phone, email, height, employer, or a family member's name and birth date."
            if !request.requested.isEmpty {
                text += " Always look for: " + request.requested.map { "\"\($0)\"" }.joined(separator: ", ") + "."
            }
        }
        text += "\nOnly what is printed; never guess. Dates as YYYY-MM-DD; US documents write dates month first."
        return text
    }
}

// MARK: Schemas

@Generable(description: "What a document is and its holder's standard facts")
nonisolated struct DeviceFacts {
    @Guide(description: "The kind of document.", .anyOf(DocumentKind.allCases.filter { $0 != .addedByYou }.map(\.rawValue)))
    var kind: String

    @Guide(description: "A short title, such as \"Passport\", \"Lease for 88 Pine Ave\" or \"Medical exam (I-693)\".")
    var title: String

    @Guide(description: "The holder's standard facts for the kind, as listed in the instructions. Omit any that aren't printed.")
    var fields: [DeviceField]
}

@Generable(description: "One standard fact")
nonisolated struct DeviceField {
    @Guide(description: "Which fact.", .anyOf(FactKey.allCases.filter { $0 != .detail }.map(\.rawValue)))
    var key: String

    @Guide(description: "As printed. Dates as YYYY-MM-DD.")
    var value: String

    @Guide(description: "low when any character is unclear; high otherwise.", .anyOf(["high", "low"]))
    var confidence: String
}

@Generable(description: "What one part of a document records")
nonisolated struct DevicePart {
    @Guide(description: "Every filled-in field, table row and result in this part.")
    var contents: [DeviceEntry]

    @Guide(description: "Details about the holder or their family useful for forms. Empty if none or if asked to leave it empty.")
    var details: [DeviceDetail]
}

@Generable(description: "One thing the document records")
nonisolated struct DeviceEntry {
    @Guide(description: "The document's section heading, such as Vaccinations or Blood tests.")
    var section: String

    @Guide(description: "The document's label, unique in its section, such as \"MMR · dose 1\" or \"Box 1 · Wages\".")
    var label: String

    @Guide(description: "The value as printed. Dates as YYYY-MM-DD.")
    var value: String

    @Guide(description: "yes when the value is an identification number on its own, such as a policy or lot number.", .anyOf(["yes", "no"]))
    var isNumber: String
}

@Generable(description: "A detail about the holder or a family member")
nonisolated struct DeviceDetail {
    @Guide(description: "holder, or the family member's relationship to the holder.", .anyOf(["holder"] + Relation.allCases.map(\.rawValue)))
    var person: String

    @Guide(description: "The family member's full name; empty for the holder.")
    var personName: String

    @Guide(description: "A short name such as Phone, Email, Height, Employer, Name or Date of birth.")
    var label: String

    @Guide(description: "The value as printed. Dates as YYYY-MM-DD.")
    var value: String

    @Guide(description: "yes for an identification number.", .anyOf(["yes", "no"]))
    var isNumber: String
}

@Generable(description: "Rows of an I-94 travel history")
nonisolated struct DeviceTravel {
    @Guide(description: "Every arrival and departure row in the text.")
    var travel: [ReadTravelEvent]
}
