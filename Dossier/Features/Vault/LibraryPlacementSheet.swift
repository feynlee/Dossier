import SwiftData
import SwiftUI

/// Renaming a document in the library, or moving it to another folder. What you set here is kept.
struct LibraryPlacementSheet: View {
    let document: SourceDocument

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ImportCoordinator.self) private var importer
    @Query private var documents: [SourceDocument]
    @State private var person = ""
    @State private var category = ""
    @State private var folder = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, axis: .vertical)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the Dossier location in Files, and to sites you upload it to. Your own file keeps its name.")
                }
                Section("Folder") {
                    suggestions("Person", text: $person, options: unique(\.person))
                    suggestions("Category", text: $category, options: unique(\.category))
                    suggestions("Folder", text: $folder, options: unique(\.folder, in: category))
                }
                if document.placementIsYours {
                    Section {
                        Button("Let Dossier Decide", systemImage: "wand.and.stars") {
                            LibraryOrganizer.resetPlacement(of: document)
                            try? modelContext.save()
                            Task { await importer.organizer.organize(context: modelContext) }
                            dismiss()
                        }
                    } footer: {
                        Text("Dossier names and files it again, and keeps it up to date from then on.")
                    }
                }
            }
            .navigationTitle("Rename or Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(cleaned.contains { $0.isEmpty })
                }
            }
            .onAppear {
                guard let placement = document.placement else { return }
                person = placement.person
                category = placement.category
                folder = placement.folder
                name = placement.name
            }
        }
    }

    private var cleaned: [String] { [person, category, folder, name].map(LibraryNaming.clean) }

    private func save() {
        let values = cleaned
        LibraryOrganizer.setYourPlacement(LibraryPlacement(person: values[0], category: values[1], folder: values[2], name: values[3]), for: document)
        try? modelContext.save()
        dismiss()
    }

    /// Values already used in the library, to pick instead of typing.
    private func unique(_ key: KeyPath<LibraryPlacement, String>, in category: String? = nil) -> [String] {
        let placements = documents.compactMap(\.placement).filter { category == nil || $0.category == category }
        return Array(Set(placements.map { $0[keyPath: key] })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func suggestions(_ label: String, text: Binding<String>, options: [String]) -> some View {
        HStack {
            TextField(label, text: text)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { text.wrappedValue = option }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .accessibilityLabel("Choose a \(label.lowercased())")
            }
        }
    }
}
