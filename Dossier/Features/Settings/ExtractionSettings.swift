import SwiftData
import SwiftUI

/// The details Dossier looks for besides each kind of document's important fields.
struct RequestedDetailsView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var documents: [SourceDocument]
    @State private var requested: [String] = []
    @State private var newName = ""
    @State private var changed = false
    @State private var confirmReread = false
    @FocusState private var isAdding: Bool

    static let suggestions = [
        "Height", "Eye colour", "Hair colour", "Marital status", "Occupation", "Employer", "Phone", "Email",
        "Social Security number", "Mother’s maiden name", "Emergency contact",
    ]

    var body: some View {
        List {
            Section {
                ForEach(requested, id: \.self) { Text($0) }
                    .onDelete { requested.remove(atOffsets: $0); save() }
                    .onMove { requested.move(fromOffsets: $0, toOffset: $1); save() }
                HStack {
                    TextField("Add a detail, like Height", text: $newName)
                        .focused($isAdding)
                        .submitLabel(.done)
                        .onSubmit { add(newName) }
                    if !newName.isEmpty {
                        Button("Add") { add(newName) }.fontWeight(.semibold)
                    }
                }
            } footer: {
                Text("Dossier looks for these on every document, as well as each document’s important fields and the family and other details it finds by itself.")
            }

            let unused = Self.suggestions.filter { suggestion in !requested.contains { $0.caseInsensitiveCompare(suggestion) == .orderedSame } }
            if !unused.isEmpty {
                Section("Suggestions") {
                    ForEach(unused, id: \.self) { suggestion in
                        Button {
                            add(suggestion)
                        } label: {
                            Label(suggestion, systemImage: "plus.circle.fill")
                        }
                    }
                }
            }

            if changed, documents.contains(where: { $0.bookmark != nil }) {
                Section {
                    Button("Read All Documents Again", systemImage: "arrow.clockwise") { confirmReread = true }
                        .disabled(importer.isRunning)
                } footer: {
                    Text("New documents use your list right away. Read the ones already added again to look for these in them too.")
                }
            }
        }
        .navigationTitle("Also look for")
        .toolbar { if !requested.isEmpty { EditButton() } }
        .onAppear { requested = DetailRequest.current.requested }
        .confirmationDialog("Read all documents again?", isPresented: $confirmReread, titleVisibility: .visible) {
            Button("Read Again") {
                importer.reread(documents, context: modelContext, preferPrivateCloud: usePrivateCloud)
                changed = false
            }
        } message: {
            Text("Each file is read again and what Dossier read before is replaced. Fields you confirmed will need confirming again. Your edits to personal information stay.")
        }
    }

    private func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty, !requested.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        withAnimation { requested.append(trimmed) }
        save()
    }

    private func save() {
        UserDefaults.standard.set(requested, forKey: DetailRequest.requestedKey)
        changed = true
    }
}
