import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Home: your compiled personal information, what needs review, and every document you added.
struct VaultView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query(sort: \SourceDocument.ingestedAt, order: .reverse) private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @State private var searchText = ""
    @State private var isPickingFolder = false
    /// A folder to choose files from: picked, or dropped on the Vault.
    @State private var pickedFolder: URL?
    @Environment(IncomingFiles.self) private var incoming
    @State private var isScanning = false
    @State private var profile = Profile(entries: [])
    /// Documents waiting for you to confirm removing them.
    @State private var removing: [SourceDocument] = []
    /// Set from the More menu: every document, to remove or read again.
    @State private var removingAll: [SourceDocument] = []
    @State private var removingSelected: [SourceDocument] = []
    @State private var rereading: [SourceDocument] = []
    @State private var rereadingSelected: [SourceDocument] = []
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<PersistentIdentifier>()
    /// The person whose documents the Vault shows; nil for everyone.
    @State private var person: String?
    /// What's open on top of the Vault, kept here so Back always returns one screen.
    @State private var path: [VaultRoute] = []

    private var isSelecting: Bool { editMode.isEditing }

    /// Documents with fields Dossier wasn't sure about.
    private var toCheck: Int {
        documents.filter { $0.isReady && $0.facts.contains { $0.status == .needsReview } }.count
    }

    private var filtered: [SourceDocument] {
        guard !searchText.isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.fileName.localizedCaseInsensitiveContains(searchText)
                || $0.kind.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Rows are selectable only in Select mode. A list that can select treats a tap on a row as a
            // selection as well as the link's push, so a folder row (which has no selection tag) opened twice
            // and the stack got out of step with the path: Back then did nothing.
            List(selection: isSelecting ? $selection : nil) {
                // Rows above the documents stay put while documents are read, so a tap lands on the row you
                // aimed at: Personal information is there from the first document, and reading progress is
                // shown at the end of the list.
                if searchText.isEmpty, !isSelecting, !documents.isEmpty {
                    Section {
                        NavigationLink(value: VaultRoute.profile) {
                            TileRow(
                                symbol: "person.crop.circle",
                                badge: !documents.contains(where: \.isReady) ? .reading : profile.conflicts.isEmpty ? .verified : .review,
                                title: "Personal information", subtitle: profileSummary
                            )
                        }
                    }
                }

                if searchText.isEmpty, !isSelecting {
                    AttentionSection(documents: documents)
                }

                if documents.isEmpty {
                    Section {
                        EmptyVault(isPicking: $isPickingFolder, isScanning: $isScanning)
                    }
                    .listRowBackground(Color.clear)
                } else if searchText.isEmpty, !isSelecting, !placed.isEmpty {
                    librarySections
                } else {
                    let statuses = lifecycle
                    let current = currentDocuments(statuses)
                    let expired = endedDocuments(statuses)
                    Section {
                        if filtered.isEmpty {
                            Text("No matches.").foregroundStyle(.secondary)
                        } else if current.isEmpty {
                            Text("Every document here has expired or been renewed.").foregroundStyle(.secondary)
                        }
                        ForEach(current) { row($0, status: statuses[$0.contentHash]) }
                    } header: {
                        Text("Documents")
                    } footer: {
                        if isSelecting {
                            Text("Removing a document deletes what Dossier read from it. The file stays where it is, so you can add it again.")
                        } else if toCheck > 0, searchText.isEmpty {
                            Text(toCheck == 1
                                ? "1 document has fields to check. Open it to compare them with the file and confirm or correct them."
                                : "\(toCheck) documents have fields to check. Open one to compare them with the file and confirm or correct them.")
                        }
                    }

                    if !expired.isEmpty {
                        Section {
                            ForEach(expired) { row($0, status: statuses[$0.contentHash]) }
                        } header: {
                            Text("Expired and renewed")
                        } footer: {
                            Text("Kept for your records. They still count for your timeline, like past addresses and trips.")
                        }
                    }
                }

                if !isSelecting {
                    ImportStatusSection()
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(isSelecting ? selectionTitle : "Vault")
            // Every link in the Vault pushes a value, so the stack stays in step: a link that pushes a view
            // directly can't sit under a link that pushes a value.
            .navigationDestination(for: VaultRoute.self) { route in
                switch route {
                case .profile: ProfileView()
                case .folder(let folder): LibraryFolderView(folder: folder)
                case .document(let id):
                    if let document = documents.first(where: { $0.persistentModelID == id }) {
                        DocumentDetailView(document: document)
                    } else {
                        ContentUnavailableView("Document removed", systemImage: "doc")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selection.count == filtered.count ? "Deselect All" : "Select All") {
                            selection = selection.count == filtered.count ? [] : Set(filtered.map(\.persistentModelID))
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { endSelecting() }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Read Again", systemImage: "arrow.clockwise") { rereadingSelected = selected }
                            .disabled(selection.isEmpty || importer.isRunning)
                            .rereadDocuments($rereadingSelected) { endSelecting() }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remove", systemImage: "trash", role: .destructive) { removingSelected = selected }
                            .tint(.red)
                            .disabled(selection.isEmpty)
                            .removeDocuments($removingSelected) { endSelecting() }
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Scan Documents", systemImage: "doc.viewfinder") { isScanning = true }
                            Button("Choose Files", systemImage: "folder") { isPickingFolder = true }
                        } label: {
                            Label("Add Documents", systemImage: "plus")
                        }
                    }
                    if !documents.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            moreMenu
                        }
                    }
                }
            }
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .chooseFromFolder(isPresented: $isPickingFolder, folder: $pickedFolder)
            .onDrop(of: [.item], isTargeted: nil) { providers in
                Task { await receive(providers) }
                return true
            }
            .fullScreenCover(isPresented: $isScanning) { DocumentScanner() }
            .removeDocuments($removing) { endSelecting() }
            .onChange(of: documents.count) { _, count in
                if count == 0 { endSelecting() }
            }
            .task(id: documents.map { "\($0.persistentModelID.hashValue)\($0.stateRaw)" } + overrides.map { "\($0.keyRaw)\($0.editedAt)" }) {
                profile = Profile.build(documents: documents, overrides: overrides)
            }
        }
    }

    /// Files dropped on the Vault are added where they are; a folder opens so you can choose files in it.
    /// Copies (from Mail, say) are handled like files shared to Dossier.
    private func receive(_ providers: [NSItemProvider]) async {
        var files: [URL] = []
        for provider in providers {
            switch await DroppedItem.load(provider) {
            case .file(let url): files.append(url)
            case .folder(let url): pickedFolder = url
            case .copy(let url): incoming.receive(url)
            case nil: break
            }
        }
        if !files.isEmpty { importer.add(files, context: modelContext, preferPrivateCloud: usePrivateCloud) }
    }

    private var selected: [SourceDocument] {
        documents.filter { selection.contains($0.persistentModelID) }
    }

    /// Actions on documents as a group. One-document actions are on the row (swipe, or touch and hold) and on
    /// the document's page.
    private var moreMenu: some View {
        Menu {
            Button("Select", systemImage: "checkmark.circle") { withAnimation { editMode = .active } }
            Button("Read All Again", systemImage: "arrow.clockwise") { rereading = documents }
                .disabled(importer.isRunning)
            Divider()
            Button("Remove All Documents", systemImage: "trash", role: .destructive) { removingAll = documents }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .rereadDocuments($rereading)
        .removeDocuments($removingAll)
    }

    // MARK: Library

    /// Documents with a place in the library, and where.
    private var placed: [(item: SourceDocument, placement: LibraryPlacement)] {
        documents.compactMap { document in document.placement.map { (item: document, placement: $0) } }
    }

    private var people: [String] {
        let placements = placed.map(\.placement)
        return LibraryGroups.people(placements, owner: LibraryGroups.owner(placements))
    }

    /// The Vault laid out like the library: a person switcher when there's more than one person, then a
    /// section per category. A folder with one document shows the document; one with several opens a list.
    @ViewBuilder private var librarySections: some View {
        let names = people
        if names.count > 1 {
            Section {
                Picker("Person", selection: $person) {
                    Text("Everyone").tag(String?.none)
                    ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        let statuses = lifecycle
        ForEach(LibraryGroups.sections(placed, person: names.count > 1 ? person : nil, status: { statuses[$0.contentHash] ?? .current })) { section in
            Section(section.isShared ? "\(section.category) · shared" : section.category) {
                ForEach(section.folders) { folder in
                    if folder.items.count == 1, let document = folder.items.first {
                        row(document, status: statuses[document.contentHash])
                    } else {
                        NavigationLink(value: VaultRoute.folder(LibraryFolderRoute(
                            person: names.count > 1 ? person : nil, category: section.category, folder: folder.name, isShared: section.isShared
                        ))) {
                            LibraryFolderRow(name: folder.name, documents: folder.items, statuses: statuses)
                        }
                        .accessibilityIdentifier("folder \(folder.name)")
                    }
                }
            }
        }
        let unplaced = documents.filter { $0.placement == nil }
        if !unplaced.isEmpty {
            Section {
                ForEach(unplaced) { row($0, status: statuses[$0.contentHash]) }
            } header: {
                Text("Not sorted yet")
            } footer: {
                Text("Dossier sorts documents into folders once it has read them.")
            }
        }
    }

    /// Each document's status: in use, expired, or renewed by a newer version.
    private var lifecycle: [String: DocumentLifecycle.Status] { documents.lifecycle() }

    /// Expired and renewed documents get their own section, below the current ones.
    private func endedDocuments(_ statuses: [String: DocumentLifecycle.Status]) -> [SourceDocument] {
        DocumentLifecycle.ordered(
            filtered.filter { statuses[$0.contentHash]?.isEnded == true },
            status: { statuses[$0.contentHash] ?? .current }, ended: { statuses[$0.contentHash]?.endedOn }
        )
    }

    private func currentDocuments(_ statuses: [String: DocumentLifecycle.Status]) -> [SourceDocument] {
        filtered.filter { statuses[$0.contentHash]?.isEnded != true }
    }

    private func row(_ document: SourceDocument, status: DocumentLifecycle.Status? = nil) -> some View {
        NavigationLink(value: VaultRoute.document(document.persistentModelID)) {
            DocumentRow(document: document, status: status)
        }
        .accessibilityIdentifier("document \(document.libraryName ?? document.title)")
        .tag(document.persistentModelID)
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) { removing = [document] }
                .tint(.red)
            Button("Read again", systemImage: "arrow.clockwise") {
                importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
            }
            .tint(Color.dsTintFill)
        }
        .contextMenu {
            Button("Read again", systemImage: "arrow.clockwise") {
                importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
            }
            Button("Remove from Vault", systemImage: "trash", role: .destructive) { removing = [document] }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select documents" : selection.count == 1 ? "1 selected" : "\(selection.count) selected"
    }

    private func endSelecting() {
        withAnimation {
            editMode = .inactive
            selection = []
        }
    }

    private var profileSummary: String {
        let name = [profile.entry(.givenNames)?.value, profile.entry(.surname)?.value].compactMap { $0 }.joined(separator: " ")
        let birth = profile.entry(.dateOfBirth)?.value.flatMap(SimpleDate.init(iso:)).map { "born \($0.display)" }
        let summary = [name.isEmpty ? nil : name, birth].compactMap { $0 }.joined(separator: " · ")
        if !profile.conflicts.isEmpty { return "Documents disagree on \(profile.conflicts.map(\.key.label).joined(separator: ", ").lowercased())" }
        return summary.isEmpty ? "Compiled from your documents" : summary
    }
}

struct DocumentRow: View {
    let document: SourceDocument
    /// Whether it's in use, expired or renewed; nil to go by its own expiry date alone.
    var status: DocumentLifecycle.Status?

    var body: some View {
        let badge = document.badge(status ?? document.lifecycleStatus)
        TileRow(
            symbol: document.isReady || document.state == .awaitingDecision ? document.kind.symbol : "doc",
            badge: badge,
            title: document.title,
            subtitle: subtitle.text,
            subtitleTone: subtitle.tone
        )
    }

    private var subtitle: (text: String, tone: SubtitleTone) {
        switch document.state {
        case .queued: return ("Waiting to be read", .plain)
        case .downloading: return ("Downloading from iCloud", .plain)
        case .reading: return ("Reading…", .plain)
        case .failed: return ("Couldn’t read: \(document.failureReason ?? "unknown error")", .warning)
        case .awaitingDecision:
            return (document.decision == .duplicate ? "Same as a document in your vault · choose a file" : "Updated version · replace the old one?", .plain)
        case .ready: break
        }
        if document.sourceMissing { return ("File removed · attach a new one", .warning) }
        let uncertain = document.facts.filter { $0.status == .needsReview }.count
        if uncertain > 0 { return (uncertain == 1 ? "1 field needs a look" : "\(uncertain) fields need a look", .plain) }
        switch status ?? document.lifecycleStatus {
        case .renewed(let ended):
            // The end that counts is when the renewal started, not the date printed on this one.
            return (ended.map { "Renewed · ended \($0.display)" } ?? "Renewed", .renewed)
        case .expired(let date):
            return (date.map { "Expired \($0.display)" } ?? "Expired", .expired)
        case .renewing(let until):
            return ("Until \(until.display) · renewal ready", .plain)
        case .current:
            break
        }
        if let expiry = document.expiryDate {
            return ("Expires \(SimpleDate(utc: expiry).display)", document.badge(.current) == .expiring ? .warning : .plain)
        }
        return (document.fileName, .plain)
    }
}

extension SourceDocument {
    /// The status from this document alone, without its renewals.
    var lifecycleStatus: DocumentLifecycle.Status {
        let entry = lifecycleEntry
        return entry.isExpired ? .expired(on: entry.expiredOn) : .current
    }

    /// The badge for this document given its status: reading and review first, then renewed or expired,
    /// then expiring soon. A document whose renewal is waiting doesn't warn that it's expiring.
    func badge(_ status: DocumentLifecycle.Status) -> TileBadge {
        let own = badge
        guard own == .verified || own == .expiring else { return own }
        switch status {
        case .renewed: return .renewed
        case .expired: return .expired
        case .renewing: return .verified
        case .current: return own
        }
    }
}

/// A folder of several documents: "I-20s · 3 documents · 2019 to 2022", badged with the one that most needs you.
/// Expired and renewed documents don't count toward its badge unless every document in it has ended.
private struct LibraryFolderRow: View {
    let name: String
    let documents: [SourceDocument]
    let statuses: [String: DocumentLifecycle.Status]

    var body: some View {
        let badges = documents.map { $0.badge(status($0)) }
        let inUse = badges.filter { !$0.isEnded }
        // When every one has ended, the badge says how the latest one ended.
        let latestRenewed = documents.first.map { status($0).isRenewed } ?? false
        let badge: TileBadge = inUse.isEmpty ? (latestRenewed ? .renewed : .expired)
            : inUse.contains(.review) ? .review : inUse.contains(.expiring) ? .expiring : inUse.contains(.reading) ? .reading : .verified
        let dates = documents.flatMap { [$0.libraryFacts.from, $0.libraryFacts.until, $0.libraryFacts.date].compactMap { $0 } }
        let subtitle = ["\(documents.count) documents", LibraryGroups.years(dates)].compactMap { $0 }.joined(separator: " · ")
        TileRow(symbol: documents.first?.kind.symbol ?? "folder", badge: badge, title: name, subtitle: subtitle)
    }

    private func status(_ document: SourceDocument) -> DocumentLifecycle.Status {
        statuses[document.contentHash] ?? document.lifecycleStatus
    }
}

/// Where a link in the Vault goes.
enum VaultRoute: Hashable {
    case profile
    case folder(LibraryFolderRoute)
    case document(PersistentIdentifier)
}

/// One library folder, as a section of the Vault shows it.
struct LibraryFolderRoute: Hashable {
    /// The person the Vault was showing; nil for everyone.
    var person: String?
    var category: String
    var folder: String
    /// The folder of Household documents shown with one person's.
    var isShared: Bool

    func contains(_ placement: LibraryPlacement) -> Bool {
        guard placement.category == category, placement.folder == folder else { return false }
        guard let person else { return true }
        return placement.person == (isShared ? LibraryPlacement.household : person)
    }
}

/// The documents in one library folder. Reads them itself, so it stays current while it's open.
struct LibraryFolderView: View {
    let folder: LibraryFolderRoute

    @Query private var documents: [SourceDocument]

    /// In use first, then expired and renewed ones.
    private func documentsShown(_ statuses: [String: DocumentLifecycle.Status]) -> [SourceDocument] {
        let placed = documents
            .compactMap { document in document.placement.map { (item: document, placement: $0) } }
            .filter { folder.contains($0.placement) }
        return LibraryGroups.ordered(placed, status: { statuses[$0.contentHash] ?? .current })
    }

    var body: some View {
        // Renewals are found across the whole vault, so a folder shows the same as the Vault does.
        let statuses = documents.lifecycle()
        let shown = documentsShown(statuses)
        List {
            ForEach(shown) { document in
                NavigationLink(value: VaultRoute.document(document.persistentModelID)) {
                    DocumentRow(document: document, status: statuses[document.contentHash])
                }
                .accessibilityIdentifier("document \(document.libraryName ?? document.title)")
            }
        }
        .overlay {
            if shown.isEmpty { ContentUnavailableView("No documents here now", systemImage: "folder") }
        }
        .navigationTitle(folder.folder)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the reader is doing, and anything it couldn't add.
private struct ImportStatusSection: View {
    @Environment(ImportCoordinator.self) private var importer

    var body: some View {
        if let current = importer.current {
            Section {
                TileRow(
                    symbol: "cloud", badge: .reading, title: "Reading \(current.name)",
                    subtitle: current.remaining == 0 ? "Last one" : "\(current.remaining) more after this"
                )
            }
        }
        if !importer.unsupportedFiles.isEmpty || !importer.duplicates.isEmpty {
            Section {
                if !importer.unsupportedFiles.isEmpty {
                    let files = importer.unsupportedFiles
                    VStack(alignment: .leading, spacing: 2) {
                        Label(files.count == 1 ? "1 file isn’t a PDF or photo" : "\(files.count) files aren’t PDFs or photos", systemImage: "doc.questionmark")
                        Text("Not added: \(files.prefix(3).joined(separator: ", "))\(files.count > 3 ? " and \(files.count - 3) more" : "").")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !importer.duplicates.isEmpty {
                    let files = importer.duplicates
                    VStack(alignment: .leading, spacing: 2) {
                        Label(files.count == 1 ? "1 file was already in your vault" : "\(files.count) files were already in your vault", systemImage: "checkmark.circle")
                        Text(files.prefix(3).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
