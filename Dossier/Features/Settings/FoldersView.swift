import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The folders Dossier reads. Add as many as you like; remove one and choose whether to keep what Dossier
/// already read from it.
struct FoldersView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var documents: [SourceDocument]
    @State private var folders = FolderAccess.folders()
    @State private var isAdding = false
    @State private var removing: FolderAccess.Folder?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if folders.isEmpty {
                    Text("No folders yet. Add the folders that hold your passport, cards, leases and notices.")
                        .foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    TileRow(symbol: "folder", badge: nil, title: folder.name, subtitle: subtitle(for: folder))
                        .swipeActions {
                            // Destructive actions keep the system red, as everywhere else in iOS; the app tint
                            // would otherwise override it.
                            Button("Remove", systemImage: "minus.circle", role: .destructive) { removing = folder }
                                .tint(.red)
                        }
                        .contextMenu {
                            Button("Remove folder", systemImage: "minus.circle", role: .destructive) { removing = folder }
                        }
                }
                Button("Add folder", systemImage: "folder.badge.plus") { isAdding = true }
            } footer: {
                Text("Dossier reads every folder here, including its subfolders. Files are read in place and never copied or changed.")
            }

            if !folders.isEmpty {
                Section {
                    Button("Check for new documents", systemImage: "arrow.clockwise") {
                        importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
                    }
                    .disabled(importer.isRunning)
                }
            }
        }
        .navigationTitle("Folders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add folder", systemImage: "plus") { isAdding = true }
            }
        }
        .fileImporter(isPresented: $isAdding, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            add(result)
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { folder in
            if documentCount(for: folder) == 0 {
                Button("Remove folder", role: .destructive) { remove(folder, deleteDocuments: false) }
            } else {
                Button("Remove folder, keep its documents") { remove(folder, deleteDocuments: false) }
                Button("Remove folder and its documents", role: .destructive) { remove(folder, deleteDocuments: true) }
            }
        } message: { folder in
            let count = documentCount(for: folder)
            Text(count == 0
                ? "Dossier stops reading this folder. Your files in it aren’t changed."
                : "Dossier stops reading this folder. You can keep the \(count == 1 ? "document" : "\(count) documents") it already read, or delete them from Dossier. Your files aren’t changed either way.")
        }
        .alert("Couldn’t add the folder", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func subtitle(for folder: FolderAccess.Folder) -> String {
        let count = documentCount(for: folder)
        let documentsText = count == 1 ? "1 document" : "\(count) documents"
        return "\(folder.displayPath) · \(documentsText)"
    }

    private func documentCount(for folder: FolderAccess.Folder) -> Int {
        documents.filter { $0.folderID == folder.id.uuidString }.count
    }

    private func add(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                for url in urls { try FolderAccess.add(url) }
            } catch {
                errorMessage = error.localizedDescription
            }
            folders = FolderAccess.folders()
            importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ folder: FolderAccess.Folder, deleteDocuments: Bool) {
        if deleteDocuments {
            for document in documents where document.folderID == folder.id.uuidString {
                modelContext.delete(document)
            }
            try? modelContext.save()
        }
        FolderAccess.remove(folder.id)
        folders = FolderAccess.folders()
        removing = nil
    }
}
