import Foundation
import FoundationModels
import ImageIO
import os

nonisolated enum ExtractorError: LocalizedError, Equatable {
    case unavailable(String)
    case quotaReached(resetDate: Date?)
    case network
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .quotaReached(let date):
            date.map { "Private Cloud Compute’s daily limit is reached. It resets \($0.formatted(.relative(presentation: .named)))." }
                ?? "Private Cloud Compute’s daily limit is reached."
        case .network: "Private Cloud Compute couldn’t be reached."
        case .failed(let message): message
        }
    }

    /// Errors that mean "try the on-device model instead" rather than "this document can't be read".
    var allowsFallback: Bool {
        switch self {
        case .unavailable, .quotaReached, .network: true
        case .failed: false
        }
    }
}

/// Reads a document with Apple's Private Cloud Compute model, falling back to the on-device model when PCC
/// can't be used. Each document gets a fresh session, so no values from one document are ever in the
/// context of another.
actor DocumentExtractor {
    private let pcc = PrivateCloudComputeLanguageModel()
    private let onDevice = SystemLanguageModel.default
    private let logger = Logger(subsystem: "liziyue.Dossier", category: "Extraction")

    /// The on-device model has an 8K context, so its OCR text is capped. PCC's 32K tokens hold roughly 25 pages
    /// of dense text, which covers leases and notices.
    private static let onDeviceTextLimit = 12_000
    private static let privateCloudTextLimit = 90_000

    /// Bumped when the instructions change enough that documents should be read again.
    static let readingVersion = 2

    static let baseInstructions = """
        You read personal documents for their owner: passports, US immigration cards and notices, driver's \
        licences, leases and travel records, and also medical exams, vaccination records, lab results, tax \
        forms, school records, bank statements and anything else people keep. You receive page images and \
        the OCR text of the same pages. The images are the source of truth; the OCR text helps with \
        hard-to-read characters but can contain mistakes.

        Read the whole document, every page, and report three things.

        1. fields: the standard facts for the document's kind.
        - passport: surname, givenNames, dateOfBirth, placeOfBirth, sex, nationality, documentNumber, issueDate, expiryDate, issuingAuthority
        - greenCard: surname, givenNames, dateOfBirth, placeOfBirth, sex, alienNumber, uscisCategory, residentSince, documentNumber, expiryDate
        - employmentAuthorization: surname, givenNames, dateOfBirth, placeOfBirth, sex, alienNumber, uscisCategory, documentNumber, validFrom, validUntil
        - visa: surname, givenNames, dateOfBirth, nationality, documentNumber, uscisCategory, issueDate, expiryDate
        - driversLicense or stateID: surname, givenNames, dateOfBirth, sex, address, documentNumber, licenseClass, issueDate, expiryDate
        - lease: address, leaseStartDate, leaseEndDate
        - uscisNotice: surname, givenNames, dateOfBirth, alienNumber, formType, receiptNumber, noticeDate, uscisCategory, validFrom, validUntil
        - i94: surname, givenNames, dateOfBirth, i94Number, classOfAdmission, admitUntil, documentNumber, plus every travel row
        - other: surname, givenNames, dateOfBirth, address, documentNumber, issueDate, expiryDate, and formType for a numbered form such as I-693

        2. contents: everything else the document records that its owner could need later, in reading \
        order, grouped by the document's own sections. Report every filled-in field, every table row and \
        every result, not a summary. For example:
        - A medical examination (such as Form I-693): each examination and test with its result, date and \
        the doctor's findings: section "Tuberculosis", label "IGRA result", value "Negative"; section \
        "Chest X-ray", label "Result", value "Normal"; and the civil surgeon's name and the exam date.
        - A vaccination certificate (such as the International Certificate of Vaccination or Prophylaxis): \
        one entry for every dose: section "Vaccinations", label "Yellow fever · dose 1", value \
        "2018-07-12 · Lot AB123 · Valid from 2018-07-22 · Travel clinic Seattle".
        - A lab report: each test with its value, unit and reference range, and any flag.
        - A tax form: each filled box with its number and label, such as "Box 1 · Wages".
        - A school record: each course or subject with its term and grade; degrees and dates.
        - A lease: rent, deposit, due day, landlord or agent, utilities and other terms.
        - A statement or notice: its dates, amounts, period and what it decides or asks for.
        Use the document's own labels. Leave out blank fields, instructions, legal fine print and form \
        boilerplate, and anything already reported in fields.

        3. details: as described below.

        Rules:
        - Report only what is printed or handwritten on the document. Never infer, guess or fill in a value \
        that is not there.
        - fields are the document holder's facts only, not a landlord's, petitioner's, doctor's or anyone \
        else's. contents can include other people where the document names them, such as the examining \
        doctor or the landlord.
        - Copy numbers exactly, character by character. Don't confuse 0 with O or 1 with I.
        - Write every date as YYYY-MM-DD. Read day-month order from the document's own convention.
        - For a machine-readable zone (lines of capital letters and < signs), prefer the printed fields above \
        it, but use the zone to resolve unclear characters.
        - Report each fact once, even if it appears on several pages.
        """

    /// The base instructions plus what to put in `details`: other useful details, and the ones you asked for.
    static func instructions(for request: DetailRequest) -> String {
        guard !request.isEmpty else { return baseInstructions + "\nLeave details empty; put everything in fields and contents." }
        var lines = ["", "Details, besides the important facts above:"]
        if request.findsUsefulDetails {
            lines += [
                "- Other details about the holder that are useful for filling in forms, such as height, eye colour, hair colour, phone, email, occupation, employer, marital status, or other names used. Don't repeat the important facts.",
                "- Family members of the holder named on the document (parents, spouse, children, siblings). Give each person's full name in personName, report their name as a detail labelled Name, and report each other detail printed about them separately, such as Date of birth, Place of birth or Nationality. Not landlords, agents, officers, employers, attorneys or anyone else who isn't family.",
            ]
        }
        if !request.requested.isEmpty {
            let list = request.requested.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("- Always look for these, for the holder unless they clearly belong to a family member, and use exactly these names as labels: \(list).")
        }
        lines.append("- Only details printed on the document; never guess. At most 30 details. Don't repeat contents.")
        return baseInstructions + lines.joined(separator: "\n")
    }

    func extract(pages: [ReadPage], preferPrivateCloud: Bool, request: DetailRequest = DetailRequest()) async throws -> (DocumentReading, ExtractionEngine) {
        let instructions = Self.instructions(for: request)
        if preferPrivateCloud {
            do {
                return (try await extractWithPrivateCloud(pages, instructions: instructions), .privateCloudCompute)
            } catch let error as ExtractorError where error.allowsFallback {
                logger.notice("PCC unavailable, using on-device model: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (try await extractOnDevice(pages, instructions: instructions), .onDevice)
    }

    /// Tells the UI whether PCC can be used right now, and why not.
    nonisolated static func privateCloudStatus() -> String? {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            return model.quotaUsage.isLimitReached ? ExtractorError.quotaReached(resetDate: model.quotaUsage.resetDate).localizedDescription : nil
        case .unavailable(.deviceNotEligible): return "This iPhone doesn’t support Private Cloud Compute."
        case .unavailable(.systemNotReady): return "Apple Intelligence isn’t ready yet."
        case .unavailable: return "Private Cloud Compute is unavailable."
        }
    }

    // MARK: Engines

    private func extractWithPrivateCloud(_ pages: [ReadPage], instructions: String) async throws -> DocumentReading {
        switch pcc.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): throw ExtractorError.unavailable("This iPhone doesn’t support Private Cloud Compute.")
        case .unavailable(.systemNotReady): throw ExtractorError.unavailable("Apple Intelligence isn’t ready yet.")
        case .unavailable: throw ExtractorError.unavailable("Private Cloud Compute is unavailable.")
        }
        if pcc.quotaUsage.isLimitReached { throw ExtractorError.quotaReached(resetDate: pcc.quotaUsage.resetDate) }

        let session = LanguageModelSession(model: pcc, instructions: instructions)
        do {
            return try await generate(in: session, pages: pages, attachImages: pcc.capabilities.contains(.vision), textLimit: Self.privateCloudTextLimit)
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            logger.error("PCC error: \(String(describing: error), privacy: .public)")
            switch error {
            case .networkFailure: throw ExtractorError.network
            case .quotaLimitReached(let details): throw ExtractorError.quotaReached(resetDate: details.resetDate)
            case .serviceUnavailable: throw ExtractorError.unavailable("Private Cloud Compute is unavailable.")
            @unknown default: throw ExtractorError.failed(String(describing: error))
            }
        } catch let error as LanguageModelError {
            if case .rateLimited(let details) = error { throw ExtractorError.quotaReached(resetDate: details.resetDate) }
            throw ExtractorError.failed(String(describing: error))
        }
    }

    private func extractOnDevice(_ pages: [ReadPage], instructions: String) async throws -> DocumentReading {
        guard onDevice.isAvailable else { throw ExtractorError.unavailable("Apple Intelligence isn’t available on this iPhone.") }
        let session = LanguageModelSession(model: onDevice, instructions: instructions)
        do {
            // Only the first page image fits alongside the text in the on-device context.
            return try await generate(
                in: session,
                pages: pages,
                attachImages: onDevice.capabilities.contains(.vision),
                maxImages: 1,
                textLimit: Self.onDeviceTextLimit
            )
        } catch {
            throw ExtractorError.failed(String(describing: error))
        }
    }

    // MARK: Prompt

    private func generate(
        in session: LanguageModelSession,
        pages: [ReadPage],
        attachImages: Bool,
        maxImages: Int = PageReader.maxImagePages,
        textLimit: Int?
    ) async throws -> DocumentReading {
        var text = pages.enumerated()
            .map { index, page in "--- Page \(index + 1) ---\n" + page.lines.joined(separator: "\n") }
            .joined(separator: "\n")
        if let textLimit, text.count > textLimit { text = String(text.prefix(textLimit)) }

        let prompt = Prompt {
            if attachImages {
                "Read this document."
                for (index, page) in pages.prefix(maxImages).enumerated() {
                    if let image = page.image {
                        Attachment(image, orientation: .up).label("page \(index + 1)")
                    }
                }
                pages.count > maxImages
                    ? "OCR text of all \(pages.count) pages (the images above show the first \(maxImages)):"
                    : "OCR text of the same pages:"
            } else {
                "Read this document from its OCR text:"
            }
            text
        }
        // Greedy sampling: transcription should be deterministic.
        let response = try await session.respond(
            to: prompt,
            generating: DocumentReading.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return response.content
    }
}
