import SwiftData
import SwiftUI

/// Home: your compiled personal information, what needs review, and every document you added.
struct VaultView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query(sort: \SourceDocument.ingestedAt, order: .reverse) private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @State private var searchText = ""
    @State private var isPickingFiles = false
    @State private var isPickingFolder = false
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
        NavigationStack {
            List(selection: $selection) {
                if searchText.isEmpty, !isSelecting, documents.contains(where: \.isReady) {
                    Section {
                        NavigationLink {
                            ProfileView()
                        } label: {
                            TileRow(symbol: "person.crop.circle", badge: profile.conflicts.isEmpty ? .verified : .review, title: "Personal information", subtitle: profileSummary)
                        }
                    }
                }

                if searchText.isEmpty, !isSelecting {
                    AttentionSection(documents: documents)
                }

                if !isSelecting {
                    ImportStatusSection()
                }

                if documents.isEmpty {
                    Section {
                        EmptyVault(isPickingFiles: $isPickingFiles, isPickingFolder: $isPickingFolder)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        if filtered.isEmpty {
                            Text("No matches.").foregroundStyle(.secondary)
                        }
                        ForEach(filtered) { document in
                            NavigationLink(value: document) {
                                DocumentRow(document: document)
                            }
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
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(isSelecting ? selectionTitle : "Vault")
            .navigationDestination(for: SourceDocument.self) { DocumentDetailView(document: $0) }
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
                            Button("Add Documents", systemImage: "doc.badge.plus") { isPickingFiles = true }
                            Button("Choose from a Folder", systemImage: "folder") { isPickingFolder = true }
                        } label: {
                            Label("Add", systemImage: "plus")
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
            .addDocuments(isPickingFiles: $isPickingFiles, isPickingFolder: $isPickingFolder)
            .removeDocuments($removing) { endSelecting() }
            .onChange(of: documents.count) { _, count in
                if count == 0 { endSelecting() }
            }
            .task(id: documents.map { "\($0.persistentModelID.hashValue)\($0.stateRaw)" } + overrides.map { "\($0.keyRaw)\($0.editedAt)" }) {
                profile = Profile.build(documents: documents, overrides: overrides)
            }
        }
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

    var body: some View {
        let badge = document.badge
        TileRow(
            symbol: document.isReady || document.state == .awaitingDecision ? document.kind.symbol : "doc",
            badge: badge,
            title: document.title,
            subtitle: subtitle,
            subtitleIsWarning: badge == .expiring || document.state == .failed || (document.sourceMissing && document.isReady)
        )
    }

    private var subtitle: String {
        switch document.state {
        case .queued: return "Waiting to be read"
        case .downloading: return "Downloading from iCloud"
        case .reading: return "Reading…"
        case .failed: return "Couldn’t read: \(document.failureReason ?? "unknown error")"
        case .awaitingDecision:
            return document.decision == .duplicate ? "Same as a document in your vault · choose a file" : "Updated version · replace the old one?"
        case .ready: break
        }
        if document.sourceMissing { return "File removed · attach a new one" }
        let uncertain = document.facts.filter { $0.status == .needsReview }.count
        if uncertain > 0 { return uncertain == 1 ? "1 field needs a look" : "\(uncertain) fields need a look" }
        if let expiry = document.expiryDate {
            return (expiry < .now ? "Expired " : "Expires ") + SimpleDate(utc: expiry).display
        }
        return document.fileName
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
