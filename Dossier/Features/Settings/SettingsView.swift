import SwiftData
import SwiftUI

struct SettingsView: View {
    @Binding var hasOnboarded: Bool

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
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
            .confirmationDialog("Re-read all documents?", isPresented: $confirmReread, titleVisibility: .visible) {
                Button("Re-read") {
                    let documents = (try? modelContext.fetch(FetchDescriptor<SourceDocument>())) ?? []
                    for document in documents where document.bookmark != nil { document.state = .queued }
                    try? modelContext.save()
                    importer.start(context: modelContext, preferPrivateCloud: usePrivateCloud)
                }
            } message: {
                Text("Each document is read again from its file and its facts replaced. Facts you confirmed will need confirming again.")
            }
            .confirmationDialog("Delete all extracted data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    importer.cancel()
                    deleteDocuments()
                    VaultKeys.shared.destroyAll()
                    FolderAccess.forgetLegacyFolders()
                    hasOnboarded = false
                }
            } message: {
                Text("Dossier forgets every fact and its keys. Your original files stay in iCloud Drive.")
            }
        }
    }

    private func deleteDocuments() {
        try? modelContext.delete(model: Fact.self)
        try? modelContext.delete(model: TravelEvent.self)
        try? modelContext.delete(model: ProfileOverride.self)
        try? modelContext.delete(model: SourceDocument.self)
        try? modelContext.save()
    }
}
