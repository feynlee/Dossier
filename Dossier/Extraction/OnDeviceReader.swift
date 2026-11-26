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
    static let partLimit = 1_200
    /// Parts read per document; the rest of a very long document is left out.
    static let maxParts = 20

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
                // The part was text only, so everything reported has to be in it (seen in testing without this: an
                // employer "Tech Corp" and a flu shot in 2027 on a lease).
                for entry in read.contents where Self.isSupported(entry.value, by: part.text) {
                    let key = [entry.section, entry.label, entry.value].joined(separator: "|").lowercased()
                    guard seen.insert(key).inserted else { continue }
                    contents.append(ReadEntry(section: entry.section, label: entry.label, value: entry.value, page: part.page, confidence: "high", isNumber: entry.isNumber))
                }
                for detail in read.details where Self.isSupported(detail.value, by: part.text) {
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
        return DocumentReading(kind: facts.kind, title: facts.title, fields: fields, contents: request.readsContents ? contents : [],
                               details: request.isEmpty ? [] : details, travel: travel)
    }

    // MARK: Steps

    private func readFacts(_ pages: [ReadPage]) async throws -> DeviceFacts {
        let text = Self.text(of: pages)
        var lastError: Error?
        for (limit, image) in [(3_000, true), (3_000, false), (1_500, false)] {
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
                return try await respond(Self.factsInstructions, prompt, DeviceFacts.self)
            } catch {
                lastError = error
                // Too long: less text. Refused by the guardrails: without the image, then with less text.
                guard DocumentExtractor.isContextOverflow(error) || Self.isGuardrail(error) else { break }
                logger.notice("On-device facts failed with \(limit) characters; trying with less")
            }
        }
        // Lab results and tax forms were refused outright in testing. Their facts are left to the parts, which
        // are read one at a time, so one refused part doesn't lose the whole document.
        if let lastError, Self.isGuardrail(lastError) {
            let title = pages.first?.lines.first { $0.count > 6 }?.trimmingCharacters(in: .whitespaces) ?? "Document"
            return DeviceFacts(kind: DocumentKind.other.rawValue, title: title, fields: [])
        }
        throw ExtractorError.failed(lastError.map { String(describing: $0) } ?? "The document couldn’t be read.")
    }

    /// One part; when its answer doesn't fit, its two halves.
    private func readPart(_ part: Part, facts: DeviceFacts, known: String) async -> [DevicePart] {
        let instructions = Self.partInstructions(kind: facts.kind, title: facts.title, known: known, request: request)
        do {
            let text = "Part of the document (page \(part.page)):\n\(part.text)"
            return [try await respond(instructions, Prompt { text }, DevicePart.self)]
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
        let instructions = "You copy rows from an I-94 travel history. Report every arrival and departure row in the text, with its date as YYYY-MM-DD and its port as printed. Only rows that are printed."
        return try await respond(instructions, Prompt { text }, DeviceTravel.self).travel
    }

    /// One fresh session. Lab results and tax forms tripped the default guardrails in testing ("May contain
    /// unsafe content"); copying what a document says is a transformation of its text, so those get a second
    /// try with the guardrails meant for that.
    private func respond<Content: Generable>(_ instructions: String, _ prompt: Prompt, _ type: Content.Type) async throws -> Content {
        let options = GenerationOptions(samplingMode: .greedy)
        do {
            return try await LanguageModelSession(model: model, instructions: instructions).respond(to: prompt, generating: type, options: options).content
        } catch let error where Self.isGuardrail(error) {
            logger.notice("On-device guardrails stopped a reading; trying with the guardrails for transforming text")
            let permissive = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            return try await LanguageModelSession(model: permissive, instructions: instructions).respond(to: prompt, generating: type, options: options).content
        }
    }

    static func isGuardrail(_ error: Error) -> Bool {
        if let error = error as? LanguageModelError, case .guardrailViolation = error { return true }
        let text = String(describing: error).lowercased()
        return text.contains("unsafe") || text.contains("guardrail")
    }

    // MARK: Text

    /// Whether a value is in the text it was read from: each date in some spelling, every number, and most words.
    static func isSupported(_ value: String, by text: String) -> Bool {
        let parts = value.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        let lines = text.components(separatedBy: "\n")
        let flat = Verifier.compact(text)
        for part in parts {
            if let date = SimpleDate(iso: part) ?? Verifier.looseDate(part, order: nil), part.contains(where: \.isNumber), part.count <= 20 {
                if Verifier.locate(date.iso, key: .issueDate, in: [lines]) == nil { return false }
                continue
            }
            let tokens = part.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
            guard !tokens.isEmpty else { continue }
            // Numbers exactly ("2,950.00" is 2 950 00), words mostly.
            let numbers = tokens.filter { $0.contains(where: \.isNumber) }
            if numbers.contains(where: { !flat.contains($0) }) { return false }
            let words = tokens.filter { !$0.contains(where: \.isNumber) }
            if !words.isEmpty, words.filter({ flat.contains($0) }).count * 3 < words.count * 2 { return false }
        }
        return true
    }

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
        Kinds: driversLicense and stateID are only driving licences and state ID cards. A health insurance card, \
        Social Security card, birth or marriage certificate, medical exam, vaccination record, lab report or tax \
        form is other. A USCIS medical exam (I-693) is other, not a work permit. On a birth certificate the \
        holder is the child: report the child's name and birth, never a parent's.
        Only the holder's facts, only what is printed; never guess. Copy numbers and names exactly as \
        printed, letter by letter (ERIKSSON stays ERIKSSON). Dates as YYYY-MM-DD; US documents write dates month \
        first. Match each date to its own label: the issue date is never the birth date. For a USCIS notice, formType is the form the notice is about \
        (such as I-485), not I-797.
        """

    static func partInstructions(kind: String, title: String, known: String, request: DetailRequest) -> String {
        guard request.readsContents else {
            // Only the fields you asked for.
            let list = request.asked.map(\.promptText).joined(separator: ", ")
            return """
                You copy fields from a personal document, one part at a time. This part is from: \(title) (\(kind)).
                Leave contents empty. In details, report each of these fields that is printed in this part, for the \
                holder even when it's about someone else the document names (such as the landlord), using exactly the \
                name as its label; the words in brackets say what the owner means: \(list.isEmpty ? "none" : list).
                Only what is printed; never guess. Dates as YYYY-MM-DD; US documents write dates month first.
                """
        }
        var text = """
            You copy what a personal document records, one part at a time. This part is from: \(title) (\(kind)). \
            Already read, so leave out: \(known.isEmpty ? "nothing" : known).
            In contents, report every filled-in field, table row and result in this part, in reading order, \
            labelled with the document's own words and grouped by its own section headings: each test and \
            result, each vaccine dose, each tax box, every amount of money with its label (rent, deposit, fees, \
            copays), parking spaces, pets and other terms, member and group numbers, and the people it names in a \
            role (doctor, landlord, employer, insurer). For a table row, the value is all its other columns \
            joined with " · ", such as "2019-04-02 · Lot AB123 · King County clinic" for a vaccine dose. Leave out \
            instructions and legal boilerplate, but not the numbers, dates and amounts inside clauses.
            """
        if request.isEmpty {
            text += "\nLeave details empty."
        } else {
            text += request.findsUsefulDetails
                ? "\nIn details, report details about the holder or their family that are useful for forms, such as phone, email, height, employer, or a family member's name and birth date."
                : "\nIn details, report only the fields asked for below."
            if !request.asked.isEmpty {
                text += " The owner asked for these fields: report each one that is printed, for the holder even when it's about someone else the document names, using exactly the name as its label; the words in brackets say what the owner means: " + request.asked.map(\.promptText).joined(separator: ", ") + "."
            }
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
