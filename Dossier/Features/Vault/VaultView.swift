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
    @State private var removing: SourceDocument?

    private var reviewCount: Int {
        documents.filter(\.isReady).reduce(0) { $0 + $1.facts.filter { $0.status == .needsReview }.count } + profile.conflicts.count
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
            List {
                if searchText.isEmpty, documents.contains(where: \.isReady) {
                    Section {
                        NavigationLink {
                            ProfileView()
                        } label: {
                            TileRow(symbol: "person.crop.circle", badge: profile.conflicts.isEmpty ? .verified : .review, title: "Personal information", subtitle: profileSummary)
                        }
                    }
                }

                if searchText.isEmpty {
                    AttentionSection(documents: documents)
                }

                if reviewCount > 0, searchText.isEmpty {
                    Section {
                        NavigationLink {
                            ReviewView()
                        } label: {
                            TileRow(
                                symbol: "doc.text.magnifyingglass",
                                badge: .review,
                                title: reviewCount == 1 ? "1 item to review" : "\(reviewCount) items to review",
                                subtitle: "Readings Dossier wasn’t sure about, and documents that disagree"
                            )
                        }
                    }
                }

                ImportStatusSection()

                Section("Documents") {
                    if documents.isEmpty {
                        Button("Add documents", systemImage: "doc.badge.plus") { isPickingFiles = true }
                        Button("Choose from a folder", systemImage: "folder") { isPickingFolder = true }
                    } else if filtered.isEmpty {
                        Text("No matches.").foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { document in
                        NavigationLink(value: document) {
                            DocumentRow(document: document)
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = document }
                                .tint(.red)
                            Button("Read again", systemImage: "arrow.clockwise") {
                                importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                            }
                            .tint(Color.dsTintFill)
                        }
                    }
                }
            }
            .navigationTitle("Vault")
            .navigationDestination(for: SourceDocument.self) { DocumentDetailView(document: $0) }
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add documents", systemImage: "doc.badge.plus") { isPickingFiles = true }
                        Button("Choose from a folder", systemImage: "folder") { isPickingFolder = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .addDocuments(isPickingFiles: $isPickingFiles, isPickingFolder: $isPickingFolder)
            .confirmationDialog(
                "Remove “\(removing?.title ?? "")”?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { document in
                Button("Remove from vault", role: .destructive) {
                    modelContext.delete(document)
                    try? modelContext.save()
                }
            } message: { _ in
                Text("Dossier forgets what it read from this document. The file itself isn’t changed.")
            }
            .task(id: documents.map { "\($0.persistentModelID.hashValue)\($0.stateRaw)" } + overrides.map { "\($0.keyRaw)\($0.editedAt)" }) {
                profile = Profile.build(documents: documents, overrides: overrides)
            }
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
