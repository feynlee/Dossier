import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Binding var hasFolder: Bool

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var isPickingFolder = false
    @State private var confirmReread = false
    @State private var confirmDelete = false
    @State private var privateCloudStatus: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $usePrivateCloud) {
                        TileRow(symbol: "cloud", badge: nil, title: "Private Cloud Compute", subtitle: "More accurate. Pages aren’t kept.")
                    }
                    Button {
                        isPickingFolder = true
                    } label: {
                        TileRow(
                            symbol: "folder",
                            badge: nil,
                            title: "Documents folder",
                            subtitle: FolderAccess.resolve().map(FolderAccess.displayPath) ?? "Not chosen"
                        )
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Reading")
                } footer: {
                    if usePrivateCloud, let privateCloudStatus {
                        Text("\(privateCloudStatus) Dossier reads on this iPhone until it’s available.")
                    } else if !usePrivateCloud {
                        Text("Reading on this iPhone is slower, and more facts will need review.")
                    }
                }

                Section("Privacy") {
                    TileRow(symbol: "faceid", badge: nil, title: "Face ID for numbers", subtitle: "Document numbers are encrypted to a key that only Face ID unlocks.")
                    TileRow(symbol: "lock", badge: nil, title: "Stays on this iPhone", subtitle: "Not included in iCloud or device backups.")
                }

                Section {
                    Button("Re-read all documents") { confirmReread = true }
                        .disabled(importer.isRunning)
                    Button("Delete all extracted data", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Dossier has no analytics and doesn’t collect data. Your original files are never changed.")
                }
            }
            .navigationTitle("Settings")
            .task { privateCloudStatus = DocumentExtractor.privateCloudStatus() }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result, (try? FolderAccess.save(url)) != nil {
                    importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            }
            .confirmationDialog("Re-read all documents?", isPresented: $confirmReread, titleVisibility: .visible) {
                Button("Re-read") {
                    deleteDocuments()
                    importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            } message: {
                Text("Facts you confirmed or edited will need review again.")
            }
            .confirmationDialog("Delete all extracted data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    importer.cancel()
                    deleteDocuments()
                    VaultKeys.shared.destroyAll()
                    FolderAccess.forget()
                    hasFolder = false
                }
            } message: {
                Text("Dossier forgets every fact and its keys. Your original files stay in iCloud Drive.")
            }
        }
    }

    private func deleteDocuments() {
        try? modelContext.delete(model: Fact.self)
        try? modelContext.delete(model: SourceDocument.self)
        try? modelContext.save()
    }
}
