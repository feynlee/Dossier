import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Home: facts to review, import progress, and every document with its badged tile.
struct VaultView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query(sort: \SourceDocument.ingestedAt, order: .reverse) private var documents: [SourceDocument]
    @State private var searchText = ""
    @State private var isAddingFolder = false
    @State private var folderError: String?

    private var reviewCount: Int {
        documents.reduce(0) { $0 + $1.facts.filter { $0.status == .needsReview }.count }
    }

    private var filtered: [SourceDocument] {
        guard !searchText.isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.kind.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.facts.contains { $0.key.label.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if reviewCount > 0 {
                    Section {
                        NavigationLink {
                            ReviewView()
                        } label: {
                            TileRow(
                                symbol: "doc.text.magnifyingglass",
                                badge: .review,
                                title: reviewCount == 1 ? "1 fact to review" : "\(reviewCount) facts to review",
                                subtitle: documents.filter(\.needsReview).map(\.title).prefix(2).joined(separator: " · ")
                            )
                        }
                    }
                }

                ImportStatusSection()

                Section("Documents") {
                    if filtered.isEmpty, !importer.isRunning {
                        if searchText.isEmpty, !FolderAccess.hasFolder {
                            Button("Add a folder", systemImage: "folder.badge.plus") { isAddingFolder = true }
                        } else {
                            Text(searchText.isEmpty ? "Documents Dossier reads will appear here." : "No matches.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(filtered) { document in
                        NavigationLink(value: document) {
                            DocumentRow(document: document)
                        }
                    }
                }
            }
            .navigationTitle("Vault")
            .fileImporter(isPresented: $isAddingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    do {
                        for url in urls { try FolderAccess.add(url) }
                        importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
                    } catch {
                        folderError = error.localizedDescription
                    }
                case .failure(let error):
                    folderError = error.localizedDescription
                }
            }
            .alert("Couldn’t add the folder", isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })) {
                Button("OK") { folderError = nil }
            } message: {
                Text(folderError ?? "")
            }
            .navigationDestination(for: SourceDocument.self) { DocumentDetailView(document: $0) }
            .searchable(text: $searchText, prompt: "Search")
            .refreshable {
                importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add folder", systemImage: "folder.badge.plus") { isAddingFolder = true }
                        Button("Check for new documents", systemImage: "arrow.clockwise") {
                            importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
                        }
                        .disabled(importer.isRunning)
                        NavigationLink {
                            FoldersView()
                        } label: {
                            Label("Manage folders", systemImage: "folder")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
    }
}

struct DocumentRow: View {
    let document: SourceDocument

    var body: some View {
        let badge = document.badge
        TileRow(
            symbol: document.kind.symbol,
            badge: badge,
            title: document.title,
            subtitle: subtitle,
            subtitleIsWarning: badge == .expiring
        )
    }

    private var subtitle: String {
        if let expiry = document.expiryDate {
            return (expiry < .now ? "Expired " : "Expires ") + SimpleDate(utc: expiry).display
        }
        return document.fileName
    }
}

/// Progress of the current or last import.
private struct ImportStatusSection: View {
    @Environment(ImportCoordinator.self) private var importer

    var body: some View {
        switch importer.phase {
        case .listing:
            Section { TileRow(symbol: "folder", badge: .reading, title: "Checking your folder…") }
        case .reading(let done, let total):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TileRow(symbol: "cloud", badge: .reading, title: "Reading \(done + 1) of \(total) documents")
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                }
            }
        case .finished, .idle:
            if importer.waitingForDownload > 0 || !importer.failures.isEmpty || importer.errorMessage != nil {
                Section {
                    if let message = importer.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                    }
                    if importer.waitingForDownload > 0 {
                        Label("\(importer.waitingForDownload) files are still downloading from iCloud.", systemImage: "icloud.and.arrow.down")
                    }
                    ForEach(importer.failures.sorted(by: { $0.key < $1.key }), id: \.key) { name, reason in
                        VStack(alignment: .leading) {
                            Text(name)
                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
