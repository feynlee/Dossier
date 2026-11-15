import AppIntents
import SwiftData
import SwiftUI

// Siri and Shortcuts. Every intent needs the device unlocked, speaks only the last four characters of a
// number, and never shows a full number: that stays behind Face ID in the app.

struct DocumentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Document"
    static let defaultQuery = DocumentQuery()

    var id: String
    var title: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: symbol))
    }

    init(_ document: SourceDocument) {
        id = document.contentHash
        title = document.kind == .addedByYou ? document.title : document.kind.displayName
        symbol = document.kind.symbol
    }
}

struct DocumentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DocumentEntity] {
        try VaultIntentData.documents().filter { identifiers.contains($0.contentHash) }.map(DocumentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [DocumentEntity] {
        try VaultIntentData.documents()
            .filter { $0.kind.displayName.localizedCaseInsensitiveContains(string) || $0.title.localizedCaseInsensitiveContains(string) }
            .map(DocumentEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [DocumentEntity] {
        try VaultIntentData.documents().filter { $0.kind != .addedByYou && $0.kind != .lease }.map(DocumentEntity.init)
    }
}

enum VaultIntentData {
    static func documents() throws -> [SourceDocument] {
        try VaultStore.container.mainContext.fetch(FetchDescriptor<SourceDocument>(sortBy: [SortDescriptor(\.ingestedAt, order: .reverse)]))
    }

    static func document(_ entity: DocumentEntity) throws -> SourceDocument {
        guard let document = try documents().first(where: { $0.contentHash == entity.id }) else {
            throw IntentError.message("That document isn’t in Dossier any more.")
        }
        return document
    }

    static func timeline() throws -> LifeTimeline {
        TimelineLoader.timeline(from: try documents())
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        }
    }
}

// MARK: Intents

struct DocumentNumberIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a document number"
    static let description = IntentDescription("Tells you the last four characters of a document’s number and when it expires.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Document") var document: DocumentEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let source = try VaultIntentData.document(document)
        guard let fact = source.fact(.documentNumber) ?? source.fact(.alienNumber) ?? source.fact(.receiptNumber) else {
            throw IntentError.message("Dossier didn’t find a number on your \(document.title.lowercased()).")
        }
        let hint = fact.sealedHint.flatMap { try? Sealer.shared.open($0) } ?? ""
        let expiry = source.fact(.expiryDate).flatMap { VaultReader.value(of: $0) }.flatMap(SimpleDate.init(iso:))
        let spoken = "Your \(document.title.lowercased()) number ends in \(hint.map(String.init).joined(separator: " "))"
            + (expiry.map { " and it expires \($0.spoken)." } ?? ".")
        return .result(dialog: "\(spoken)") {
            IntentSnippet(symbol: document.symbol, title: document.title, value: VaultReader.masked(fact), detail: expiry.map { "Expires \($0.display) · open Dossier to reveal" } ?? "Open Dossier to reveal")
        }
    }
}

struct ExpiryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check when a document expires"
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Document") var document: DocumentEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let source = try VaultIntentData.document(document)
        let expiry = source.fact(.expiryDate).flatMap { VaultReader.value(of: $0) }.flatMap(SimpleDate.init(iso:))
        guard let expiry else {
            throw IntentError.message("Dossier didn’t find an expiry date on your \(document.title.lowercased()).")
        }
        let verb = expiry < .today ? "expired" : "expires"
        return .result(dialog: "Your \(document.title.lowercased()) \(verb) \(expiry.spoken).")
    }
}

struct WhereDidILiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Find where I lived"
    static let description = IntentDescription("Tells you your address in a given year, from your leases and records.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Year", requestValueDialog: "Which year?") var year: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let timeline = try VaultIntentData.timeline()
        let homes = timeline.homes(in: year)
        guard let last = homes.last else {
            return .result(dialog: "Dossier doesn’t have an address for \(String(year)).") {
                IntentSnippet(symbol: "house", title: String(year), value: "No address on file", detail: "Add one in the Timeline tab")
            }
        }
        let spoken = homes.count == 1
            ? "In \(String(year)) you lived at \(last.address)."
            : "In \(String(year)) you lived at \(homes.count) addresses. The last was \(last.address)."
        return .result(dialog: "\(spoken)") {
            IntentSnippet(symbol: "house", title: String(year), value: last.address, detail: "\(intervalText(last.start, last.end)) · \(last.source)")
        }
    }
}

struct DaysAbroadIntent: AppIntent {
    static let title: LocalizedStringResource = "Count days outside the US"
    static let description = IntentDescription("Counts days outside the US in a year from your I-94 travel history.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresLocalDeviceAuthentication

    @Parameter(title: "Year", requestValueDialog: "Which year?") var year: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let timeline = try VaultIntentData.timeline()
        let trips = timeline.trips(in: year)
        let days = timeline.daysAbroad(in: year)
        let tripText = trips.count == 1 ? "1 trip" : "\(trips.count) trips"
        return .result(dialog: "In \(String(year)) you spent \(days) days outside the US, over \(tripText).")
    }
}

struct DossierShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskDossierIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Look something up in \(.applicationName)",
            ],
            shortTitle: "Ask Dossier",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: SearchDossierIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
                "Find something in \(.applicationName)",
            ],
            shortTitle: "Search Dossier",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetFactIntent(),
            phrases: [
                "What’s \(\.$fact) in \(.applicationName)",
                "What is \(\.$fact) in \(.applicationName)",
                "Get \(\.$fact) from \(.applicationName)",
                "Find \(\.$fact) in \(.applicationName)",
                "Look up \(\.$fact) in \(.applicationName)",
            ],
            shortTitle: "Look up a fact",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: DocumentNumberIntent(),
            phrases: [
                "What’s my \(\.$document) number in \(.applicationName)",
                "Get my \(\.$document) number from \(.applicationName)",
            ],
            shortTitle: "Document number",
            systemImageName: "person.text.rectangle"
        )
        AppShortcut(
            intent: ExpiryIntent(),
            phrases: ["When does my \(\.$document) expire in \(.applicationName)"],
            shortTitle: "Expiry date",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: WhereDidILiveIntent(),
            phrases: ["Where did I live with \(.applicationName)", "Ask \(.applicationName) where I lived"],
            shortTitle: "Where I lived",
            systemImageName: "house"
        )
        AppShortcut(
            intent: DaysAbroadIntent(),
            phrases: ["How many days was I abroad in \(.applicationName)", "Ask \(.applicationName) about days abroad"],
            shortTitle: "Days abroad",
            systemImageName: "airplane"
        )
    }
}

/// The card Siri shows under its answer: the same badged tile as the app.
struct IntentSnippet: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            BadgedTile(symbol: symbol, badge: .verified)
            VStack(alignment: .leading, spacing: 2) {
                Text("DOSSIER · \(title.uppercased())").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.dsFieldValue)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

nonisolated extension SimpleDate {
    /// "14 March 2029", for speech.
    var spoken: String {
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        return "\(day) \(months[month - 1]) \(year)"
    }
}
