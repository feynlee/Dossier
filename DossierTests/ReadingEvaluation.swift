import Foundation
import Testing
@testable import Dossier

/// Reads every file of the made-up household (SampleDocuments/Household) with the app's real pipeline: Vision
/// OCR, barcode and MRZ parsing, the language model, and the verifier. It writes one JSON file per document for
/// `Tools/household/score_reading.py` to score against the answer key. Nothing is asserted here: accuracy is a
/// number to track, not a pass/fail.
///
/// Off unless asked for, because it takes minutes and uses Private Cloud Compute quota:
///
///     TEST_RUNNER_DOSSIER_EVAL_DIR=/path/to/SampleDocuments/Household \
///     TEST_RUNNER_DOSSIER_EVAL_OUT=/path/to/results \
///     TEST_RUNNER_DOSSIER_EVAL_ENGINE=pcc|device \
///     xcodebuild test -scheme Dossier -only-testing:DossierTests/ReadingEvaluation …
@Suite(.enabled(if: ReadingEvaluation.folder != nil), .serialized)
struct ReadingEvaluation {
    nonisolated static var folder: URL? {
        ProcessInfo.processInfo.environment["DOSSIER_EVAL_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    nonisolated struct Output: Codable {
        struct Field: Codable { var key: String; var value: String; var page: Int; var confidence: String }
        struct Entry: Codable { var section: String; var label: String; var value: String; var page: Int; var confidence: String; var isNumber: String }
        struct Detail: Codable { var person: String; var personName: String; var label: String; var value: String; var confidence: String }
        struct Travel: Codable { var date: String; var kind: String; var port: String }
        struct Verified: Codable { var key: String; var value: String; var status: String; var check: String; var alternate: String? }

        var file: String
        var engine: String?
        var seconds: Double
        var error: String?
        var pageCount = 0
        var ocrLines = 0
        var barcodeFound = false
        var barcodeParsed = false
        var mrzFound = false
        var mrzValid = false
        var mrzFailedChecks: [String] = []
        var kind: String?
        var title: String?
        var fields: [Field] = []
        var contents: [Entry] = []
        var details: [Detail] = []
        var travel: [Travel] = []
        /// What the app keeps after the verifier: only the kind's important facts, with their status.
        var verified: [Verified] = []
    }

    @Test(.timeLimit(.minutes(90)))
    func readHousehold() async throws {
        let folder = try #require(Self.folder)
        let environment = ProcessInfo.processInfo.environment
        let usePrivateCloud = environment["DOSSIER_EVAL_ENGINE"] != "device"
        let output = URL(filePath: environment["DOSSIER_EVAL_OUT"] ?? folder.appending(path: "results").path(), directoryHint: .isDirectory)
            .appending(path: usePrivateCloud ? "pcc" : "device", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let only = environment["DOSSIER_EVAL_ONLY"]

        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["pdf", "jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .filter { only == nil || $0.lastPathComponent.localizedCaseInsensitiveContains(only!) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let extractor = DocumentExtractor()

        for file in files {
            let target = output.appending(path: file.deletingPathExtension().lastPathComponent + ".json")
            if environment["DOSSIER_EVAL_RESUME"] != nil, FileManager.default.fileExists(atPath: target.path()) { continue }
            let started = Date.now
            var result = Output(file: file.lastPathComponent, seconds: 0)
            do {
                let data = try Data(contentsOf: file)
                let pages = try await PageReader.read(data, fileName: file.lastPathComponent)
                let lines = pages.map(\.lines)
                let mrz = MRZParser.find(in: lines.flatMap { $0 })
                let license = pages.flatMap(\.barcodes).lazy.compactMap(AAMVAParser.parse).first
                result.pageCount = pages.count
                result.ocrLines = lines.map(\.count).reduce(0, +)
                result.barcodeFound = pages.contains { !$0.barcodes.isEmpty }
                result.barcodeParsed = license != nil
                result.mrzFound = mrz != nil
                result.mrzValid = mrz?.isValid ?? false
                result.mrzFailedChecks = mrz?.failedChecks ?? []

                let (reading, engine) = try await extractor.extract(pages: pages, preferPrivateCloud: usePrivateCloud, request: DetailRequest())
                result.engine = engine.rawValue
                result.kind = reading.kind
                result.title = reading.title
                result.fields = reading.fields.map { .init(key: $0.key, value: $0.value, page: $0.page, confidence: $0.confidence) }
                result.contents = reading.contents.map {
                    .init(section: $0.section, label: $0.label, value: $0.value, page: $0.page, confidence: $0.confidence, isNumber: $0.isNumber)
                }
                result.details = reading.details.map {
                    .init(person: $0.person, personName: $0.personName, label: $0.label, value: $0.value, confidence: $0.confidence)
                }
                result.travel = reading.travel.map { .init(date: $0.date, kind: $0.kind, port: $0.port) }

                let kind = DocumentKind(rawValue: reading.kind) ?? .other
                let important = Set(kind.importantKeys)
                let inputs = reading.fields.compactMap { field -> Verifier.Input? in
                    guard let key = FactKey(rawValue: field.key), important.contains(key) else { return nil }
                    return Verifier.Input(key: key, value: field.value, page: max(1, field.page), isConfident: field.confidence != "low")
                }
                result.verified = Verifier.verify(inputs, pages: lines, mrz: mrz, license: license)
                    .filter { important.contains($0.key) }
                    .map { .init(key: $0.key.rawValue, value: $0.value, status: $0.status.rawValue, check: $0.check.rawValue, alternate: $0.alternate) }
            } catch {
                result.error = String(describing: error)
            }
            result.seconds = Date.now.timeIntervalSince(started)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(result).write(to: target)
        }
    }
}
