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

    static let instructions = """
        You read personal documents for their owner: passports, US immigration cards and notices, driver's \
        licences, leases and travel records. You receive page images and the OCR text of the same pages. \
        The images are the source of truth; the OCR text helps with hard-to-read characters but can contain \
        mistakes.

        Report only the important facts for the document's kind:
        - passport: surname, givenNames, dateOfBirth, placeOfBirth, sex, nationality, documentNumber, issueDate, expiryDate, issuingAuthority
        - greenCard: surname, givenNames, dateOfBirth, placeOfBirth, sex, alienNumber, uscisCategory, residentSince, documentNumber, expiryDate
        - employmentAuthorization: surname, givenNames, dateOfBirth, placeOfBirth, sex, alienNumber, uscisCategory, documentNumber, validFrom, validUntil
        - visa: surname, givenNames, dateOfBirth, nationality, documentNumber, uscisCategory, issueDate, expiryDate
        - driversLicense or stateID: surname, givenNames, dateOfBirth, sex, address, documentNumber, licenseClass, issueDate, expiryDate
        - lease: address, leaseStartDate, leaseEndDate
        - uscisNotice: surname, givenNames, dateOfBirth, alienNumber, formType, receiptNumber, noticeDate, uscisCategory, validFrom, validUntil
        - i94: surname, givenNames, dateOfBirth, i94Number, classOfAdmission, admitUntil, documentNumber, plus every travel row
        - other: surname, givenNames, dateOfBirth, address, documentNumber, issueDate, expiryDate

        Rules:
        - Report only facts printed on the document. Never infer, guess or fill in a value that is not printed.
        - Report the document holder's facts only, not a landlord's, petitioner's, officer's or anyone else's.
        - Copy numbers exactly, character by character. Don't confuse 0 with O or 1 with I.
        - Write every date as YYYY-MM-DD. Read day-month order from the document's own convention.
        - For a machine-readable zone (lines of capital letters and < signs), prefer the printed fields above \
        it, but use the zone to resolve unclear characters.
        - One field per fact. If a fact appears on several pages, report it once.
        """

    func extract(pages: [ReadPage], preferPrivateCloud: Bool) async throws -> (DocumentReading, ExtractionEngine) {
        if preferPrivateCloud {
            do {
                return (try await extractWithPrivateCloud(pages), .privateCloudCompute)
            } catch let error as ExtractorError where error.allowsFallback {
                logger.notice("PCC unavailable, using on-device model: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (try await extractOnDevice(pages), .onDevice)
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

    private func extractWithPrivateCloud(_ pages: [ReadPage]) async throws -> DocumentReading {
        switch pcc.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): throw ExtractorError.unavailable("This iPhone doesn’t support Private Cloud Compute.")
        case .unavailable(.systemNotReady): throw ExtractorError.unavailable("Apple Intelligence isn’t ready yet.")
        case .unavailable: throw ExtractorError.unavailable("Private Cloud Compute is unavailable.")
        }
        if pcc.quotaUsage.isLimitReached { throw ExtractorError.quotaReached(resetDate: pcc.quotaUsage.resetDate) }

        let session = LanguageModelSession(model: pcc, instructions: Self.instructions)
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

    private func extractOnDevice(_ pages: [ReadPage]) async throws -> DocumentReading {
        guard onDevice.isAvailable else { throw ExtractorError.unavailable("Apple Intelligence isn’t available on this iPhone.") }
        let session = LanguageModelSession(model: onDevice, instructions: Self.instructions)
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
