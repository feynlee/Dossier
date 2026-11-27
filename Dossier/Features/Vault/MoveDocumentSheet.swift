import SwiftData
import SwiftUI

/// Moves documents to another category and folder, from a drop on a shelf or Move to… on a tile. With
/// Remember this on, your words are saved as a rule on that category: the on-device model follows your rules
/// before its own lines, and you can edit them in Settings › Categories.
struct MoveDocumentSheet: View {
    let documents: [SourceDocument]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ImportCoordinator.self) private var importer
    @Query private var library: [SourceDocument]
    @AppStorage(CategoryList.storageKey) private var categoriesJSON = ""
    @State private var category: String
    @State private var folder: String
    @State private var remembers = true
    @State private var rule = ""
    /// True once you typed in the rule, so changing the category no longer rewrites it.
    @State private var ruleIsEdited = false
    @State private var isNaming = false
    @State private var newName = ""
    @State private var isAdding = false

    init(documents: [SourceDocument], category: String? = nil) {
        self.documents = documents
        let current = documents.first?.placement
        _category = State(initialValue: category ?? current?.category ?? CategoryList.other)
        _folder = State(initialValue: current?.folder ?? "")
    }

    private var categories: CategoryList { CategoryList(json: categoriesJSON) }

    /// The folder these documents are in now: offered in any category, so a move keeps them together.
    private var ownFolder: String? { documents.first?.placement?.folder }

    /// Folders in the chosen category, and the documents' own folder as a new one when it isn't there yet.
    private var folders: [(name: String, isNew: Bool)] {
        let used = Set(library.compactMap(\.placement).filter { categories.resolve($0.category) == category }.map(\.folder))
        var list = used.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (name: $0, isNew: false) }
        if let ownFolder, !used.contains(ownFolder) { list.insert((name: ownFolder, isNew: true), at: 0) }
        return list
    }

    private var subtitle: String {
        documents.count == 1
            ? documents[0].libraryName ?? documents[0].title
            : "\(documents.count) documents in \(ownFolder ?? "this folder")"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(subtitle).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                Section("Category") {
                    ForEach(categories.names, id: \.self) { name in
                        Button {
                            category = name
                        } label: {
                            HStack(spacing: 12) {
                                Circle().fill(CategoryStyle.of(name).tint).frame(width: 12, height: 12)
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                if name == category {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.dsTint)
                                        .accessibilityLabel("Selected")
                                }
                            }
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(name == category ? .isSelected : [])
                    }
                    Button("New Category…", systemImage: "plus") { newName = ""; isNaming = true }
                        .disabled(isAdding)
                }

                Section("Folder in \(category)") {
                    ForEach(folders, id: \.name) { option in
                        Button {
                            folder = option.name
                        } label: {
                            HStack {
                                Text(option.name).foregroundStyle(.primary)
                                Spacer()
                                if option.isNew { Text("new").font(.footnote).foregroundStyle(.secondary) }
                                if option.name == folder {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.dsTint)
                                        .accessibilityLabel("Selected")
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    TextField("Folder name", text: $folder)
                }

                Section {
                    Toggle("Remember this", isOn: $remembers)
                    if remembers {
                        TextField("Rule, in your words", text: $rule, axis: .vertical)
                            .onChange(of: rule) { _, new in if new != suggestedRule { ruleIsEdited = true } }
                    }
                } header: {
                    Text("Your rule")
                } footer: {
                    if remembers {
                        Text("Dossier follows your rules before its own. You’ll find this rule as Yours on the \(category) page in Settings › Categories.")
                    }
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { move() }.disabled(LibraryNaming.clean(folder).isEmpty || isAdding)
                }
            }
            .alert("New Category", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Add") { Task { await addCategory() } }
            } message: {
                Text("A new shelf in the Vault. Dossier writes a few lines on what goes in it.")
            }
            .onAppear { rule = suggestedRule }
            .onChange(of: category) { _, _ in
                if !ruleIsEdited { rule = suggestedRule }
            }
            .onChange(of: folder) { _, _ in
                if !ruleIsEdited { rule = suggestedRule }
            }
        }
    }

    /// "Hotel bookings go in Travel": the folder's kind of document, then the category.
    private var suggestedRule: String {
        let what = LibraryNaming.clean(folder).isEmpty ? (documents.first?.kind.displayName ?? "These documents") : LibraryNaming.clean(folder)
        return "\(what) go in \(category)"
    }

    private func addCategory() async {
        let name = CategoryList.clean(newName)
        guard !name.isEmpty else { return }
        if let existing = categories.resolve(name) {
            category = existing
            return
        }
        isAdding = true
        let lines = await CategoryLinesModel.lines(for: name, in: categories) ?? []
        CategoryList.update { $0.add(name, lines: lines) }
        categoriesJSON = CategoryList.current.json
        category = CategoryList.current.resolve(name) ?? name
        isAdding = false
    }

    private func move() {
        let folder = LibraryNaming.clean(folder)
        for document in documents {
            guard let placement = document.placement else { continue }
            LibraryOrganizer.setYourPlacement(
                LibraryPlacement(person: placement.person, category: category, folder: folder, name: placement.name),
                for: document
            )
        }
        try? modelContext.save()
        if remembers {
            let text = rule
            let target = category
            CategoryList.update { $0.addRule(text, to: target) }
        }
        // Moves the files in iCloud Drive › Dossier to match.
        Task { await importer.organizer.organize(context: modelContext) }
        dismiss()
    }
}
