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

    /// PCC's 32K tokens hold roughly 25 pages of dense text, which covers leases and notices. The on-device
    /// model reads in parts instead; see `OnDeviceReader`.
    private static let privateCloudTextLimit = 90_000

    /// Bumped when the instructions change enough that documents should be read again.
    static let readingVersion = 4

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

        2. contents: everything else on the document that is relevant to it or could be useful to its \
        owner later, especially anything another form might ask for. Decide what that is from the document \
        itself; no list limits it. Report every filled-in field, every table row and every result, not a \
        summary, in reading order, grouped by the document's own sections and labelled with its own words. \
        For instance: each test and result on a medical exam, every dose on a vaccination record (date, \
        lot, clinic), each box on a tax form, each course and grade on a transcript, a lease's rent and \
        terms, the people the document names in a role (doctor, landlord, employer, school). Leave out \
        blank fields, instructions, legal fine print and form boilerplate, and anything already reported \
        in fields.

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
        - For a USCIS notice (an I-797), formType is the form the notice is about, such as I-485 or I-765, not I-797.
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
                return (Self.withTravelRows(try await extractWithPrivateCloud(pages, instructions: instructions), pages: pages), .privateCloudCompute)
            } catch let error as ExtractorError where error.allowsFallback {
                logger.notice("PCC unavailable, using on-device model: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (Self.withTravelRows(try await extractOnDevice(pages, request: request), pages: pages), .onDevice)
    }

    /// Facts printed under fixed labels as OCR shows them, and an I-94's travel rows when OCR finds at least as
    /// many as the model did.
    nonisolated static func withTravelRows(_ reading: DocumentReading, pages: [ReadPage]) -> DocumentReading {
        var reading = LabelValueParser.apply(to: CardFieldParser.apply(to: reading, pages: pages), pages: pages)
        guard reading.kind == DocumentKind.i94.rawValue else { return reading }
        let parsed = TravelHistoryParser.rows(in: pages)
        guard parsed.count >= reading.travel.count, !parsed.isEmpty else { return reading }
        reading.travel = parsed
        return reading
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
            logger.error("PCC model error: \(String(describing: error), privacy: .public)")
            // Content the model won't read is a property of the document; anything else (seen in testing: a burst
            // of ModelManager errors once many documents were read in a row) is PCC not being usable right now,
            // so the on-device model reads it and Private Cloud Compute reads it again later.
            let text = String(describing: error).lowercased()
            if text.contains("unsafe") || text.contains("guardrail") { throw ExtractorError.failed(String(describing: error)) }
            throw ExtractorError.unavailable("Private Cloud Compute couldn’t read it right now.")
        } catch let error as CancellationError {
            throw error
        } catch {
            // Seen in testing: ModelManagerError 1001 thrown as neither error type above, for every document
            // once PCC stopped answering. That's PCC being unusable, not the document.
            logger.error("PCC failed: \(String(describing: error), privacy: .public)")
            let text = String(describing: error).lowercased()
            if text.contains("unsafe") || text.contains("guardrail") { throw ExtractorError.failed(String(describing: error)) }
            throw ExtractorError.unavailable("Private Cloud Compute couldn’t read it right now.")
        }
    }

    private func extractOnDevice(_ pages: [ReadPage], request: DetailRequest) async throws -> DocumentReading {
        guard onDevice.isAvailable else { throw ExtractorError.unavailable("Apple Intelligence isn’t available on this iPhone.") }
        return try await OnDeviceReader(model: onDevice, request: request).read(pages)
    }

    nonisolated static func isContextOverflow(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("context") && (text.contains("exceed") || text.contains("maximum"))
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
