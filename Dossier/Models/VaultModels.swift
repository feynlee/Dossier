import CoreGraphics
import Foundation
import SwiftData

/// A file you added to the vault. The file itself is never copied: Dossier keeps a bookmark to it, a content
/// hash for de-duplication, and the one set of facts extracted from it.
@Model
final class SourceDocument {
    /// The file's SHA-256 once read; "pending-…" until then.
    @Attribute(.unique) var contentHash: String
    var fileName: String
    /// Security-scoped bookmark to the file, for reading it again and showing it next to its facts.
    var bookmark: Data?
    var stateRaw: String = DocumentState.ready.rawValue
    /// Why the file couldn't be read, when `state` is `.failed`.
    var failureReason: String?
    /// Earlier versions found files through folders; kept only to give those documents a bookmark.
    var relativePath: String = ""
    var folderID: String = ""
    /// The file's size and modification date when it was read (0 and nil if unknown), so an unchanged file
    /// can be recognised without downloading it again from iCloud.
    var fileSize: Int = 0
    var fileModifiedAt: Date?
    var kindRaw: String
    var title: String
    var ingestedAt: Date
    var engineRaw: String
    var pageCount: Int
    @Relationship(deleteRule: .cascade, inverse: \Fact.document) var facts: [Fact] = []
    @Relationship(deleteRule: .cascade, inverse: \TravelEvent.document) var travel: [TravelEvent] = []

    init(contentHash: String, fileName: String, relativePath: String = "", folderID: String = "", kind: DocumentKind, title: String, engine: ExtractionEngine, pageCount: Int) {
        self.contentHash = contentHash
        self.fileName = fileName
        self.relativePath = relativePath
        self.folderID = folderID
        self.kindRaw = kind.rawValue
        self.title = title
        self.ingestedAt = .now
        self.engineRaw = engine.rawValue
        self.pageCount = pageCount
    }

    /// A file you just added, waiting to be read.
    static func pending(fileName: String, bookmark: Data) -> SourceDocument {
        let document = SourceDocument(
            contentHash: "pending-\(UUID().uuidString)", fileName: fileName, kind: .other,
            title: (fileName as NSString).deletingPathExtension, engine: .privateCloudCompute, pageCount: 0
        )
        document.bookmark = bookmark
        document.state = .queued
        return document
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .other }
    var engine: ExtractionEngine { ExtractionEngine(rawValue: engineRaw) ?? .onDevice }

    var state: DocumentState {
        get { DocumentState(rawValue: stateRaw) ?? .ready }
        set { stateRaw = newValue.rawValue }
    }

    var isReady: Bool { state == .ready }

    var needsReview: Bool { facts.contains { $0.status == .needsReview } }

    func fact(_ key: FactKey) -> Fact? {
        facts.first { $0.key == key && $0.status != .superseded }
    }

    var expiryDate: Date? {
        facts.first { $0.key == .expiryDate && $0.status != .superseded }?.plainDate
    }

    /// The single badge shown on this document's icon tile.
    var badge: TileBadge {
        switch state {
        case .queued, .downloading, .reading: return .reading
        case .failed: return .review
        case .ready: break
        }
        if needsReview { return .review }
        if let expiryDate, expiryDate < Calendar.current.date(byAdding: .month, value: 6, to: .now)! { return .expiring }
        return .verified
    }
}

/// One extracted value. Values are sealed: `sealedValue` is AES-GCM ciphertext under the vault key, or,
/// for sensitive facts, ciphertext only the Face ID–gated key can open.
@Model
final class Fact {
    var keyRaw: String
    var sealedValue: Data
    var isSensitive: Bool
    /// For sensitive facts: the last four characters, sealed under the vault key, so lists and Siri can say
    /// "ends in 4821" without Face ID.
    var sealedHint: Data?
    var statusRaw: String
    var checkRaw: String
    /// A second reading that disagreed with the first, sealed the same way as the value.
    var sealedAlternate: Data?
    /// The OCR line the value was found on, sealed under the vault key.
    var sealedContext: Data?
    var page: Int
    /// Issue, expiry and lease dates in the clear, for sorting and expiry badges. Never set for birth dates.
    var plainDate: Date?
    /// A keyed hash of the normalized value (HMAC under the vault key). Lets Dossier tell whether two
    /// documents show the same A-Number without decrypting either.
    var fingerprint: Data?
    /// Where the value was read: the 1-based page and the line's box, normalized with a top-left origin.
    var cropPage: Int?
    var cropX: Double?
    var cropY: Double?
    var cropWidth: Double?
    var cropHeight: Double?
    /// The line this value was read from also shows a sensitive number, so its crop needs Face ID.
    var cropRevealsNumber = false
    var document: SourceDocument?

    /// Whether the source crop can be shown without Face ID.
    var cropNeedsFaceID: Bool { isSensitive || cropRevealsNumber }

    var cropRect: CGRect? {
        guard let cropX, let cropY, let cropWidth, let cropHeight else { return nil }
        return CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
    }

    func setCrop(page: Int, rect: CGRect) {
        cropPage = page
        cropX = rect.minX
        cropY = rect.minY
        cropWidth = rect.width
        cropHeight = rect.height
    }

    init(key: FactKey, sealedValue: Data, sealedHint: Data?, status: FactStatus, check: FactCheck, page: Int) {
        self.keyRaw = key.rawValue
        self.sealedValue = sealedValue
        self.isSensitive = key.isSensitive
        self.sealedHint = sealedHint
        self.statusRaw = status.rawValue
        self.checkRaw = check.rawValue
        self.page = page
    }

    var key: FactKey { FactKey(rawValue: keyRaw) ?? .documentNumber }

    var status: FactStatus {
        get { FactStatus(rawValue: statusRaw) ?? .needsReview }
        set { statusRaw = newValue.rawValue }
    }

    var check: FactCheck {
        get { FactCheck(rawValue: checkRaw) ?? .unchecked }
        set { checkRaw = newValue.rawValue }
    }
}

/// One arrival or departure from an I-94 travel history. Values are sealed like facts.
@Model
final class TravelEvent {
    var uuid = UUID()
    var sealedDate: Data
    var isArrival: Bool
    var sealedPort: Data
    /// For a departure: where the user says they went. Entered by hand; I-94 records don't say.
    var sealedDestination: Data?
    var document: SourceDocument?

    init(sealedDate: Data, isArrival: Bool, sealedPort: Data) {
        self.sealedDate = sealedDate
        self.isArrival = isArrival
        self.sealedPort = sealedPort
    }
}

/// Where a document is in the reading pipeline.
nonisolated enum DocumentState: String, Codable, Sendable {
    case queued
    case downloading
    case reading
    case ready
    case failed
}

/// A value you set for your compiled personal information, replacing what the documents say.
@Model
final class ProfileOverride {
    @Attribute(.unique) var keyRaw: String
    var sealedValue: Data
    var isSensitive: Bool
    var editedAt: Date

    init(key: String, sealedValue: Data, isSensitive: Bool) {
        self.keyRaw = key
        self.sealedValue = sealedValue
        self.isSensitive = isSensitive
        self.editedAt = .now
    }
}

nonisolated enum FactStatus: String, Codable, Sendable {
    case needsReview
    case verified
    case superseded
}

/// How a value was checked, shown as "Verified · checked against the MRZ".
nonisolated enum FactCheck: String, Codable, Sendable {
    case mrz
    case barcode
    case pageText
    case userConfirmed
    case conflict
    case model
    case unchecked

    var summary: String {
        switch self {
        case .mrz: "checked against the MRZ"
        case .barcode: "checked against the barcode"
        case .pageText: "found in the page text"
        case .userConfirmed: "confirmed by you"
        case .conflict: "the readings differ"
        case .model: "read with high confidence"
        case .unchecked: "not checked yet"
        }
    }
}

nonisolated enum ExtractionEngine: String, Codable, Sendable {
    case privateCloudCompute
    case onDevice

    var displayName: String {
        switch self {
        case .privateCloudCompute: "Private Cloud Compute"
        case .onDevice: "On this iPhone"
        }
    }
}
