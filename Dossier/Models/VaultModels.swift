import CoreGraphics
import Foundation
import SwiftData

/// A file in the user's documents folder that Dossier has read. The file itself is never copied: only its
/// name, a content hash for de-duplication, and the facts extracted from it.
@Model
final class SourceDocument {
    @Attribute(.unique) var contentHash: String
    var fileName: String
    /// The file's path inside its folder, for re-reading a page to show a source crop.
    var relativePath: String = ""
    /// Which of your folders the file is in (`FolderAccess.Folder.id`). Empty for documents you added by hand
    /// and for documents read before Dossier supported several folders.
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

    init(contentHash: String, fileName: String, relativePath: String, folderID: String = "", kind: DocumentKind, title: String, engine: ExtractionEngine, pageCount: Int) {
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

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .other }
    var engine: ExtractionEngine { ExtractionEngine(rawValue: engineRaw) ?? .onDevice }

    var needsReview: Bool { facts.contains { $0.status == .needsReview } }

    func fact(_ key: FactKey) -> Fact? {
        facts.first { $0.key == key && $0.status != .superseded }
    }

    var expiryDate: Date? {
        facts.first { $0.key == .expiryDate && $0.status != .superseded }?.plainDate
    }

    /// The single badge shown on this document's icon tile.
    var badge: TileBadge {
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
    case unchecked

    var summary: String {
        switch self {
        case .mrz: "checked against the MRZ"
        case .barcode: "checked against the barcode"
        case .pageText: "found in the page text"
        case .userConfirmed: "confirmed by you"
        case .conflict: "the readings differ"
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
