import Foundation
import SwiftData

/// A file in the user's documents folder that Dossier has read. The file itself is never copied: only its
/// name, a content hash for de-duplication, and the facts extracted from it.
@Model
final class SourceDocument {
    @Attribute(.unique) var contentHash: String
    var fileName: String
    var kindRaw: String
    var title: String
    var ingestedAt: Date
    var engineRaw: String
    var pageCount: Int
    @Relationship(deleteRule: .cascade, inverse: \Fact.document) var facts: [Fact] = []

    init(contentHash: String, fileName: String, kind: DocumentKind, title: String, engine: ExtractionEngine, pageCount: Int) {
        self.contentHash = contentHash
        self.fileName = fileName
        self.kindRaw = kind.rawValue
        self.title = title
        self.ingestedAt = .now
        self.engineRaw = engine.rawValue
        self.pageCount = pageCount
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .other }
    var engine: ExtractionEngine { ExtractionEngine(rawValue: engineRaw) ?? .onDevice }

    var needsReview: Bool { facts.contains { $0.status == .needsReview } }

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
    var document: SourceDocument?

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
