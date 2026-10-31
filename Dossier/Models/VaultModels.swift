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
    /// The source file was deleted or can't be reached any more. What was read from it stays usable.
    var sourceMissing: Bool = false
    /// You chose to keep the document without its file, so Dossier stops asking.
    var missingAcknowledged: Bool = false
    /// Fingerprints (HMAC under the vault key) of what identifies the document, its issue/expiry dates, and
    /// all its important facts. Used to spot a second file for the same document without decrypting anything.
    var identityKey: String?
    var versionKey: String?
    var contentSignature: String?
    /// For a document in `.awaitingDecision`: whether it duplicates or updates another, and which one.
    var decisionRaw: String?
    var relatedHash: String?
    /// Documents you chose to keep alongside this one, so the question isn't asked again.
    var keptAlongside: [String] = []
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
    /// Fields you deleted (`Fact.fieldID`), left out when the document is read again.
    var dismissedFields: [String] = []
    @Relationship(deleteRule: .cascade, inverse: \TravelEvent.document) var travel: [TravelEvent] = []
    /// Where the document sits in the library and what it's called there. Set by `LibraryOrganizer`, or by
    /// you, in which case Dossier never changes it.
    var libraryPerson: String?
    var libraryCategory: String?
    var libraryFolder: String?
    var libraryName: String?
    var placementIsYours: Bool = false
    /// `DocumentExtractor.readingVersion` when the document was read with Private Cloud Compute, one less
    /// when it was read on this iPhone; 0 for documents read before versions were kept.
    var readVersion: Int = 0

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

    /// The start of a content hash for a file that hasn't been read yet.
    static let pendingPrefix = "pending-"

    /// A file you just added, waiting to be read.
    static func pending(fileName: String, bookmark: Data) -> SourceDocument {
        let document = SourceDocument(
            contentHash: "\(pendingPrefix)\(UUID().uuidString)", fileName: fileName, kind: .other,
            title: (fileName as NSString).deletingPathExtension, engine: .privateCloudCompute, pageCount: 0
        )
        document.bookmark = bookmark
        document.state = .queued
        return document
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .other }

    var placement: LibraryPlacement? {
        get {
            guard let libraryPerson, let libraryCategory, let libraryFolder, let libraryName else { return nil }
            return LibraryPlacement(person: libraryPerson, category: libraryCategory, folder: libraryFolder, name: libraryName)
        }
        set {
            libraryPerson = newValue?.person
            libraryCategory = newValue?.category
            libraryFolder = newValue?.folder
            libraryName = newValue?.name
        }
    }
    var engine: ExtractionEngine { ExtractionEngine(rawValue: engineRaw) ?? .onDevice }

    var state: DocumentState {
        get { DocumentState(rawValue: stateRaw) ?? .ready }
        set { stateRaw = newValue.rawValue }
    }

    var isReady: Bool { state == .ready }

    /// Removed from the vault (deleted, or deleted and saved).
    var isGone: Bool { isDeleted || modelContext == nil }

    var decision: DocumentMatch? {
        switch decisionRaw {
        case "duplicate": .duplicate
        case "update": .update
        default: nil
        }
    }

    var keys: DocumentKeys { DocumentKeys(identity: identityKey, version: versionKey, signature: contentSignature ?? "") }

    var needsReview: Bool { facts.contains { $0.status == .needsReview } }

    func fact(_ key: FactKey) -> Fact? {
        facts.first { $0.key == key && $0.status != .superseded }
    }

    /// Read, and past its expiry date.
    var isExpired: Bool { isReady && (expiryDate.map { $0 < .now } ?? false) }

    var expiryDate: Date? {
        facts.first { $0.key == .expiryDate && $0.status != .superseded }?.plainDate
    }

    /// The single badge shown on this document's icon tile.
    var badge: TileBadge {
        switch state {
        case .queued, .downloading, .reading: return .reading
        case .failed, .awaitingDecision: return .review
        case .ready: break
        }
        if sourceMissing { return .review }
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
    /// For a detail: its name, such as "Height" or "Date of birth".
    var label: String?
    /// For a detail: whose it is. Nil for the document's holder.
    var relationRaw: String?
    /// For a family member's detail: their name, sealed under the vault key.
    var sealedPersonName: Data?
    /// For something the document records (a test result, a vaccine dose): the document's section it's in,
    /// such as "Vaccinations". Nil for facts and details.
    var section: String?
    /// Its place in the document's reading order.
    var position: Int = 0
    var document: SourceDocument?

    var relation: Relation? { relationRaw.flatMap(Relation.init(rawValue:)) }
    var personName: String? { sealedPersonName.flatMap { try? Sealer.shared.open($0) } }

    /// "Height", "Mother · Date of birth", "Child (EMMA) · Place of birth", or the fact's standard label.
    var displayLabel: String {
        guard key == .detail else { return key.label }
        let name = label ?? "Detail"
        guard let relation else { return name }
        if name.caseInsensitiveCompare("Name") == .orderedSame { return "\(relation.label)’s name" }
        if let person = personName, !person.isEmpty { return "\(relation.label) (\(person.split(separator: " ").first ?? "")) · \(name)" }
        return "\(relation.label) · \(name)"
    }

    /// Identifies the field on its document, so a field you deleted isn't read back in. Names in it are
    /// fingerprints, not text.
    var fieldID: String {
        guard key == .detail else { return keyRaw }
        if let section { return Self.entryID(section: section, label: label ?? "") }
        return Self.detailID(label: label ?? "", relation: relationRaw, personName: personName)
    }

    static func entryID(section: String, label: String) -> String {
        "entry|\(section.lowercased())|\(label.lowercased())"
    }

    static func detailID(label: String, relation: String?, personName: String?) -> String {
        let person = personName.flatMap { $0.isEmpty ? nil : try? Sealer.shared.fingerprint($0.uppercased()).base64EncodedString() } ?? ""
        return "detail|\(relation ?? "holder")|\(person)|\(label.lowercased())"
    }

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
    /// Read, but it duplicates or updates another document: waiting for you to choose.
    case awaitingDecision
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

/// A family member's relationship to a document's holder.
nonisolated enum Relation: String, CaseIterable, Codable, Sendable {
    case father, mother, spouse, child, sibling, other

    var label: String {
        switch self {
        case .father: "Father"
        case .mother: "Mother"
        case .spouse: "Spouse"
        case .child: "Child"
        case .sibling: "Sibling"
        case .other: "Family member"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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
