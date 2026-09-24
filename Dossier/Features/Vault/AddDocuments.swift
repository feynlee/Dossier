import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The two ways to add documents: pick files (several at once), or pick a folder and tick the files to add.
/// Only the files you add are read.
struct AddDocumentsModifier: ViewModifier {
    @Binding var isPickingFiles: Bool
    @Binding var isPickingFolder: Bool
    var onAdded: () -> Void = {}

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var folder: PickedFolder?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: FileAccess.readableTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    if importer.add(urls, context: modelContext, preferPrivateCloud: usePrivateCloud) > 0 { onAdded() }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            // A second importer on the same view doesn't present; attach it to a background view instead.
            .background {
                Color.clear.fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): folder = PickedFolder(url: url)
                    case .failure(let error): errorMessage = error.localizedDescription
                    }
                }
            }
            .sheet(item: $folder) { folder in
                FolderFilePicker(folder: folder.url) { urls in
                    if importer.add(urls, within: folder.url, context: modelContext, preferPrivateCloud: usePrivateCloud) > 0 { onAdded() }
                }
            }
            .alert("Couldn’t add documents", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

private struct PickedFolder: Identifiable {
    let id = UUID()
    let url: URL
}

extension View {
    func addDocuments(isPickingFiles: Binding<Bool>, isPickingFolder: Binding<Bool>, onAdded: @escaping () -> Void = {}) -> some View {
        modifier(AddDocumentsModifier(isPickingFiles: isPickingFiles, isPickingFolder: isPickingFolder, onAdded: onAdded))
    }
}

/// The files in a folder you picked, to tick the ones to add.
struct FolderFilePicker: View {
    let folder: URL
    let onAdd: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var documents: [SourceDocument]
    @State private var listing: FolderAccess.Listing?
    @State private var selected: Set<URL> = []
    @State private var errorMessage: String?

    /// Files already in the vault, by path.
    private var addedPaths: Set<String> {
        Set(documents.compactMap { $0.bookmark.flatMap(FileAccess.resolve)?.url.standardizedFileURL.path })
    }

    private func isAdded(_ file: FolderAccess.FolderFile) -> Bool {
        addedPaths.contains(file.url.standardizedFileURL.path)
    }

    var body: some View {
        NavigationStack {
            List {
                if let listing {
                    let available = listing.files.filter { !isAdded($0) }
                    Section {
                        if listing.files.isEmpty {
                            Text("No PDFs or photos in this folder.").foregroundStyle(.secondary)
                        }
                        ForEach(listing.files) { file in
                            let added = isAdded(file)
                            Button {
                                if selected.contains(file.url) { selected.remove(file.url) } else { selected.insert(file.url) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: added || selected.contains(file.url) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(added ? Color.secondary : Color.dsTint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.relativePath).foregroundStyle(.primary)
                                        if added {
                                            Text("Already in your vault").font(.footnote).foregroundStyle(.secondary)
                                        } else if !file.isDownloaded {
                                            Label("In iCloud · downloads when added", systemImage: "icloud.and.arrow.down")
                                                .font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .disabled(added)
                        }
                    } header: {
                        if !available.isEmpty {
                            HStack {
                                Text("\(available.count) not in your vault")
                                Spacer()
                                Button(selected.count == available.count ? "Deselect all" : "Select all") {
                                    selected = selected.count == available.count ? [] : Set(available.map(\.url))
                                }
                                .textCase(nil)
                            }
                        }
                    } footer: {
                        if !listing.unsupported.isEmpty {
                            Text("\(listing.unsupported.count) other files aren’t PDFs or photos, so they aren’t shown.")
                        }
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.dsWarning)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(folder.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                        onAdd(Array(selected))
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .task {
                do {
                    listing = try await Self.list(folder)
                } catch {
                    errorMessage = "The folder couldn’t be opened: \(error.localizedDescription)"
                }
            }
        }
    }

    @concurrent
    private static func list(_ folder: URL) async throws -> FolderAccess.Listing {
        try FolderAccess.list(folder)
    }
}
