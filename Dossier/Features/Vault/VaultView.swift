import AppIntents
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Home: your compiled personal information, what needs review, and every document you added.
struct VaultView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    /// Siri's tip ("Ask Dossier…") under Personal information until you close it: nobody guesses Siri phrases.
    @AppStorage("showsSiriTip") private var showsSiriTip = true
    @Query(sort: \SourceDocument.ingestedAt, order: .reverse) private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @State private var searchText = ""
    /// Key documents you pinned, took out or reordered (`KeyDocuments` as JSON).
    @AppStorage(KeyDocuments.storageKey) private var keyDocumentsJSON = ""
    /// Set by the search button, or by pulling the Vault down past its top, which opens search.
    @State private var isSearchPresented = false
    /// The Key document brought forward from the wallet.
    @State private var focusedCard: SourceDocument?
    /// Documents on their way to another shelf, from a drop or Move to….
    @State private var moving: MoveRequest?
    @State private var isPickingFiles = false
    /// A folder dropped on the Vault, to choose files from.
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
    /// What's open on top of the Vault, kept here so Back always returns one screen.
    @State private var path: [VaultRoute] = []

    private var isSelecting: Bool { editMode.isEditing }

    /// Documents with fields Dossier wasn't sure about.
    private var toCheck: Int {
        documents.filter { $0.isReady && $0.facts.contains { $0.status == .needsReview } }.count
    }

    private var filtered: [SourceDocument] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return documents }
        return documents.filter { $0.matches(query) }
    }

    /// The Vault as a wallet and shelves: nothing typed, not selecting, and some documents sorted.
    private var showsLibrary: Bool {
        searchText.isEmpty && !isSelecting && !documents.isEmpty && !placed.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Rows are selectable only in Select mode. A list that can select treats a tap on a row as a
            // selection as well as the link's push, so a folder row (which has no selection tag) opened twice
            // and the stack got out of step with the path: Back then did nothing.
            List(selection: isSelecting ? $selection : nil) {
                if showsLibrary {
                    // Wallet first, then Personal information and anything that needs you, then the shelves.
                    librarySections
                } else {
                    // Rows above the documents stay put while documents are read, so a tap lands on the row you
                    // aimed at: Personal information is there from the first document, and reading progress is
                    // shown at the end of the list.
                    summarySections
                    flatSections
                }

                if !isSelecting {
                    ImportStatusSection()
                }
            }
            .environment(\.editMode, $editMode)
            // Pull to search: dragging the Vault well past its top opens the search field.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < -70
            } action: { _, isPulled in
                if isPulled, !isSelecting, !documents.isEmpty, !isSearchPresented { isSearchPresented = true }
            }
            .navigationTitle(isSelecting ? selectionTitle : "Vault")
            // Every link in the Vault pushes a value, so the stack stays in step: a link that pushes a view
            // directly can't sit under a link that pushes a value.
            .navigationDestination(for: VaultRoute.self) { route in
                switch route {
                case .profile:
                    ProfileView { document, fact in
                        if let fact {
                            path.append(.field(document: document.persistentModelID, fact: fact.persistentModelID))
                        } else {
                            path.append(.document(document.persistentModelID))
                        }
                    }
                case .folder(let folder): LibraryFolderView(folder: folder)
                case .category(let category): LibraryCategoryView(route: category)
                case .document(let id):
                    if let document = documents.first(where: { $0.persistentModelID == id }) {
                        DocumentDetailView(document: document)
                    } else {
                        ContentUnavailableView("Document removed", systemImage: "doc")
                    }
                case .field(let id, let fact):
                    if let document = documents.first(where: { $0.persistentModelID == id }) {
                        DocumentDetailView(document: document, focus: fact)
                    } else {
                        ContentUnavailableView("Document removed", systemImage: "doc")
                    }
                }
            }
            // Hidden above the wallet until you tap Search or pull the Vault down.
            .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search documents and facts")
            .searchSuggestions {
                if searchText.isEmpty {
                    ForEach(typeSuggestions, id: \.self) { name in
                        Label(name, systemImage: "folder").searchCompletion(name)
                    }
                }
            }
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
                        Button("Read Again…", systemImage: "arrow.clockwise") { rereadingSelected = selected }
                            .disabled(selection.isEmpty || importer.isRunning)
                            .readAgainSheet($rereadingSelected) { endSelecting() }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remove", systemImage: "trash", role: .destructive) { removingSelected = selected }
                            .tint(.red)
                            .disabled(selection.isEmpty)
                            .removeDocuments($removingSelected) { endSelecting() }
                    }
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !documents.isEmpty {
                            Button("Search", systemImage: "magnifyingglass") { isSearchPresented = true }
                                .accessibilityIdentifier("search documents")
                        }
                        Menu {
                            AddDocumentsMenuItems(isPickingFiles: $isPickingFiles, isScanning: $isScanning)
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
            .addDocuments(choosingFiles: $isPickingFiles, folder: $pickedFolder)
            .onDrop(of: [.item], isTargeted: nil) { providers in
                Task { await receive(providers) }
                return true
            }
            .fullScreenCover(isPresented: $isScanning) { DocumentScanner() }
            .sheet(item: $moving) { request in
                MoveDocumentSheet(documents: request.documents, category: request.category)
            }
            .sheet(item: $focusedCard) { document in
                WalletFocusView(document: document, cards: walletCards) { open in
                    path.append(.document(open.persistentModelID))
                }
            }
            .removeDocuments($removing) { endSelecting() }
            .onChange(of: documents.count) { _, count in
                if count == 0 { endSelecting() }
            }
            .task(id: documents.map { "\($0.persistentModelID.hashValue)\($0.stateRaw)" } + overrides.map { "\($0.keyRaw)\($0.editedAt)" }) {
                profile = Profile.build(documents: documents, overrides: overrides)
            }
        }
    }

    /// Personal information, Siri's tip and documents that need you.
    @ViewBuilder private var summarySections: some View {
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

        if searchText.isEmpty, !isSelecting, showsSiriTip, documents.contains(where: \.isReady) {
            Section {
                SiriTipView(intent: AskDossierIntent(), isVisible: $showsSiriTip)
            } footer: {
                Text("Or ask Siri to “find my blood type in Dossier”.")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        if searchText.isEmpty, !isSelecting {
            AttentionSection(documents: documents)
        }
    }

    /// Documents as one list: when searching, selecting, or before anything is sorted. Expired and
    /// renewed ones get their own section, below the current ones.
    @ViewBuilder private var flatSections: some View {
        if documents.isEmpty {
            Section {
                EmptyVault(isPickingFiles: $isPickingFiles, isScanning: $isScanning)
            }
            .listRowBackground(Color.clear)
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

    /// Folder names to jump to from an empty search, in shelf order.
    private var typeSuggestions: [String] {
        var seen = Set<String>()
        return LibraryGroups.sections(placed, person: nil).flatMap { $0.folders.map(\.name) }.filter { seen.insert($0).inserted }
    }

    /// The Vault laid out like a wallet and shelves, with everyone's documents together: IDs as cards,
    /// then a shelf per category. A tile with one document opens it; a tile with several
    /// opens the folder, and See all opens the whole category.
    @ViewBuilder private var librarySections: some View {
        // Everyone's documents together: each card and tile says whose it is where that helps.
        let shownPerson: String? = nil
        let statuses = lifecycle
        let cards = walletCards
        if !cards.isEmpty {
            Section {
                WalletStack(documents: cards) { focusedCard = $0 }
            } header: {
                HStack {
                    Text("Key documents")
                    Spacer()
                    NavigationLink("Edit") { KeyDocumentsSettingsView() }
                        .font(.subheadline)
                        .textCase(nil)
                        .accessibilityIdentifier("edit key documents")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }

        summarySections

        // Files you just added come first, so you see them arrive and get read; each moves to its shelf
        // once it's read.
        let unplaced = documents.filter { $0.placement == nil }
        if !unplaced.isEmpty {
            Section {
                ForEach(unplaced) { row($0, status: statuses[$0.contentHash]) }
            } header: {
                Text("Not sorted yet")
            } footer: {
                Text("Dossier sorts documents onto shelves once it has read them.")
            }
        }
        // Cards in the wallet aren't on the shelves too.
        let inWallet = Set(cards.map(\.contentHash))
        let shelved = placed.filter { !inWallet.contains($0.item.contentHash) }
        ForEach(LibraryGroups.sections(shelved, person: shownPerson, status: { statuses[$0.contentHash] ?? .current })) { section in
            Section {
                CategoryShelf(
                    section: section, person: shownPerson, statuses: statuses,
                    onReread: { importer.reread($0, context: modelContext, preferPrivateCloud: usePrivateCloud) },
                    onRemove: { removing = [$0] },
                    onMove: { moving = MoveRequest(documents: $0, category: $1) },
                    onDrop: { hashes, category in
                        let dropped = documents.filter { hashes.contains($0.contentHash) && $0.placement != nil }
                        // A drop on the shelf it's already on does nothing.
                        guard !dropped.isEmpty, dropped.contains(where: { $0.placement?.category != category }) else { return }
                        moving = MoveRequest(documents: dropped, category: category)
                    }
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listSectionSpacing(.compact)
        }
    }

    /// Key documents in the wallet, back to front.
    private var walletCards: [SourceDocument] {
        let statuses = lifecycle
        return WalletStack.cards(placed.map(\.item), keys: KeyDocuments(json: keyDocumentsJSON)) {
            statuses[$0.contentHash] ?? $0.lifecycleStatus
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

extension SourceDocument {
    /// Whether a search finds this document: its title, file, type, place in the library, or a fact you can
    /// read without Face ID. Numbers stay hidden, so their last digits don't match.
    func matches(_ query: String) -> Bool {
        let fields = [title, fileName, kind.displayName, libraryCategory, libraryFolder, libraryPerson].compactMap { $0 }
        if fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        return facts.contains { fact in
            guard fact.status != .superseded, !fact.isSensitive else { return false }
            if fact.displayLabel.localizedCaseInsensitiveContains(query) { return true }
            return VaultReader.value(of: fact)?.localizedCaseInsensitiveContains(query) ?? false
        }
    }
}

/// Where a link in the Vault goes.
enum VaultRoute: Hashable {
    case profile
    case folder(LibraryFolderRoute)
    /// A category's See all, from its shelf.
    case category(LibraryCategoryRoute)
    case document(PersistentIdentifier)
    /// A document opened on one of its fields, from Personal information.
    case field(document: PersistentIdentifier, fact: PersistentIdentifier)
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
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true

    var body: some View {
        if importer.waitingForCloud > 0 {
            Section {
                TileRow(
                    symbol: "icloud.slash", badge: nil,
                    title: importer.waitingForCloud == 1 ? "1 file waiting for Private Cloud Compute" : "\(importer.waitingForCloud) files waiting for Private Cloud Compute",
                    subtitle: importer.cloudStatus ?? "Read when it’s available."
                )
                Button("Read on This iPhone Now", systemImage: "iphone") {
                    importer.readWaitingNow(context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            } footer: {
                Text("Reading on this iPhone misses more on long files. Dossier reads them again with Private Cloud Compute later, unless you’ve confirmed or edited something.")
            }
        }
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

/// Documents to move, and the shelf they were dropped on (nil from Move to…).
struct MoveRequest: Identifiable {
    let id = UUID()
    let documents: [SourceDocument]
    let category: String?
}
