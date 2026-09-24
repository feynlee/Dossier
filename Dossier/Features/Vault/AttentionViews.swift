import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Documents that need you: a second file for the same document, or a source file that was removed.
struct AttentionSection: View {
    let documents: [SourceDocument]

    @State private var deciding: SourceDocument?
    @State private var missing: SourceDocument?

    private var decisions: [SourceDocument] { documents.filter { $0.state == .awaitingDecision } }
    private var removed: [SourceDocument] { documents.filter { $0.sourceMissing && !$0.missingAcknowledged && $0.state != .awaitingDecision } }

    var body: some View {
        if !decisions.isEmpty || !removed.isEmpty {
            Section("Needs your attention") {
                ForEach(decisions) { document in
                    Button { deciding = document } label: {
                        TileRow(
                            symbol: document.kind.symbol, badge: .review,
                            title: document.decision == .duplicate ? "Two files for the same \(document.kind.displayName.lowercased())" : "Updated \(document.kind.displayName.lowercased())",
                            subtitle: document.decision == .duplicate ? "Choose which file to keep: \(document.fileName)" : "Replace the one in your vault with \(document.fileName)?"
                        )
                    }
                    .foregroundStyle(.primary)
                }
                ForEach(removed) { document in
                    Button { missing = document } label: {
                        TileRow(symbol: document.kind.symbol, badge: .review, title: "File removed: \(document.title)", subtitle: "\(document.fileName) was deleted or can’t be found. Attach a new file.")
                    }
                    .foregroundStyle(.primary)
                }
            }
            .sheet(item: $deciding) { DocumentDecisionSheet(document: $0) }
            .sheet(item: $missing) { MissingSourceSheet(document: $0) }
        }
    }
}

// MARK: Duplicate or update

struct DocumentDecisionSheet: View {
    let document: SourceDocument

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var documents: [SourceDocument]

    private var other: SourceDocument? {
        documents.first { $0.contentHash == document.relatedHash }
    }

    var body: some View {
        NavigationStack {
            List {
                if document.decision == .duplicate {
                    duplicate
                } else {
                    update
                }
            }
            .navigationTitle(document.decision == .duplicate ? "Same document, two files" : "Updated document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
    }

    @ViewBuilder
    private var duplicate: some View {
        Section {
            Text("These files show the same \(document.kind.displayName.lowercased()). Choose which file Dossier keeps as its source. What you already confirmed stays.")
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        if let other {
            Section("In your vault") {
                FileSummary(document: other)
                Button("Keep this file", systemImage: "checkmark.circle") { decide(.keepExisting) }
            }
        }
        Section("Just added") {
            FileSummary(document: document)
            Button("Use this file instead", systemImage: "arrow.left.arrow.right") { decide(.useNewFile) }
        }
    }

    @ViewBuilder
    private var update: some View {
        Section {
            Text("This is the same \(document.kind.displayName.lowercased()) as one in your vault, with different details. Replace the old one with this file?")
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        if let other {
            let changes = differences(from: other)
            Section {
                if changes.isEmpty {
                    Text("Only numbers differ, which stay masked here.").foregroundStyle(.secondary)
                }
                ForEach(changes, id: \.key) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.key.label).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(change.old).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.footnote).foregroundStyle(.tertiary)
                            Text(change.new)
                        }
                        .font(change.key.isMonospaced ? .dsFieldValue : .body)
                    }
                }
            } header: {
                Text("What changed")
            }
            Section("Files") {
                FileSummary(document: other, label: "In your vault")
                FileSummary(document: document, label: "New file")
            }
        }
        Section {
            Button("Replace with the new file", systemImage: "arrow.triangle.2.circlepath") { decide(.replace) }
            Button("Keep both", systemImage: "square.on.square") { decide(.keepBoth) }
            Button("Don’t add this file", role: .destructive) { decide(.discardNew) }
        }
    }

    private struct Change {
        var key: FactKey
        var old: String
        var new: String
    }

    /// Fields whose readable values differ. Sensitive numbers aren't opened here.
    private func differences(from other: SourceDocument) -> [Change] {
        document.kind.importantKeys.compactMap { key in
            guard !key.isSensitive else { return nil }
            let old = other.fact(key).flatMap { VaultReader.value(of: $0) }.map { VaultReader.display($0, for: key) }
            let new = document.fact(key).flatMap { VaultReader.value(of: $0) }.map { VaultReader.display($0, for: key) }
            guard old != new else { return nil }
            return Change(key: key, old: old ?? "—", new: new ?? "—")
        }
    }

    private func decide(_ decision: ImportCoordinator.Decision) {
        importer.resolve(document, with: decision, context: modelContext)
        dismiss()
    }
}

/// A file's name, where it is, and when it was added.
struct FileSummary: View {
    let document: SourceDocument
    var label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label { Text(label).font(.footnote).foregroundStyle(.secondary) }
            Text(document.fileName)
            Text(document.locationDescription ?? "Location unknown")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Added \(document.ingestedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

extension SourceDocument {
    /// "iCloud Drive › Documents › IDs": the folder the file is in now. Follows the file if it was moved.
    var locationDescription: String? {
        guard let url = bookmark.flatMap(FileAccess.resolve)?.url else { return nil }
        return FolderAccess.displayPath(for: url.deletingLastPathComponent())
    }
}

// MARK: Removed file

struct MissingSourceSheet: View {
    let document: SourceDocument

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var isPicking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(document.fileName) was deleted, moved to the Trash, or moved somewhere Dossier can’t follow. Dossier still has what it read from it. Attach the file again, or a new copy, so you can compare and re-read it.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Button("Attach a file", systemImage: "paperclip") { isPicking = true }
                    Button("Keep without a file", systemImage: "checkmark") {
                        document.missingAcknowledged = true
                        try? modelContext.save()
                        dismiss()
                    }
                    Button("Remove document", role: .destructive) {
                        modelContext.delete(document)
                        try? modelContext.save()
                        dismiss()
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Color.dsWarning)
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .fileImporter(isPresented: $isPicking, allowedContentTypes: FileAccess.readableTypes) { result in
                switch result {
                case .success(let url):
                    do {
                        try importer.attach(url, to: document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
