import SwiftData
import SwiftUI

// MARK: Categories

/// Settings › Library › Categories: your categories in shelf order. Each one is a shelf in the Vault and a
/// top-level folder in the library. The on-device model files documents into these only.
struct CategoriesSettingsView: View {
    @AppStorage(CategoryList.storageKey) private var json = ""
    @Query private var documents: [SourceDocument]
    @State private var isAdding = false

    private var list: CategoryList { CategoryList(json: json) }

    var body: some View {
        List {
            Section {
                ForEach(list.categories) { category in
                    NavigationLink {
                        CategoryDetailView(name: category.name)
                    } label: {
                        CategoryRow(category: category, count: count(category.name))
                    }
                    .moveDisabled(category.name == CategoryList.other)
                    .deleteDisabled(category.name == CategoryList.other)
                    .accessibilityIdentifier("category row \(category.name)")
                }
                .onMove { source, destination in
                    CategoryList.update { $0.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    let names = offsets.map { list.categories[$0].name }
                    CategoryList.update { list in names.forEach { list.delete($0) } }
                }
            } footer: {
                Text("Each category is a shelf in the Vault, in this order. Tap Edit to reorder or delete. Other is always last.")
            }

            Section {
                Button("Add Category", systemImage: "plus") { isAdding = true }
                    .accessibilityIdentifier("add category")
            }
        }
        .navigationTitle("Categories")
        .toolbar { EditButton() }
        .sheet(isPresented: $isAdding) { AddCategorySheet() }
    }

    private func count(_ name: String) -> Int {
        let list = self.list
        return documents.filter { !$0.isGone && $0.libraryCategory.map { list.resolve($0) ?? $0 } == name }.count
    }
}

/// One category in a list: its shelf color, its name and its first lines.
struct CategoryRow: View {
    let category: CategoryDefinition
    var count: Int?

    var body: some View {
        let style = CategoryStyle.of(category.name)
        HStack(spacing: 12) {
            BadgedTile(symbol: style.symbol, badge: nil, size: 32, tint: style.tint, soft: style.soft)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                Text(category.includes.map(\.text).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// A sheet to name a new category. The on-device model then writes its lines.
struct AddCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isWriting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as Pets", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Dossier writes what goes in it on this iPhone. You can change the lines after.")
                    }
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWriting {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await add() } }
                            .disabled(CategoryList.clean(name).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add() async {
        let name = CategoryList.clean(name)
        guard !name.isEmpty else { return }
        let list = CategoryList.current
        guard !list.names.contains(where: { $0.lowercased() == name.lowercased() }) else {
            error = "There’s already a category called \(name)."
            return
        }
        isWriting = true
        let lines = await CategoryLinesModel.lines(for: name, in: list) ?? []
        CategoryList.update { $0.add(name, lines: lines) }
        isWriting = false
        dismiss()
    }
}

// MARK: One category

/// A category's page: its name and its filing lines. "What goes here" lines say what belongs in it; "Not
/// here" lines send similar documents to another category. Editing a Suggested line makes it yours.
struct CategoryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CategoryList.storageKey) private var json = ""
    @State private var name: String
    @State private var draftName = ""
    @State private var newInclude = ""
    @State private var newExclusion = ""
    @State private var newExclusionTarget = CategoryList.other
    @State private var isConfirmingDelete = false

    init(name: String) {
        _name = State(initialValue: name)
    }

    private var list: CategoryList { CategoryList(json: json) }
    private var category: CategoryDefinition? { list.category(named: name) }
    private var isOther: Bool { name == CategoryList.other }

    var body: some View {
        Group {
            if let category {
                form(category)
            } else {
                ContentUnavailableView("Category deleted", systemImage: "tray")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draftName = name }
    }

    private func form(_ category: CategoryDefinition) -> some View {
        let style = CategoryStyle.of(category.name)
        let targets = list.names.filter { $0 != category.name }
        return Form {
            Section {
                HStack(spacing: 12) {
                    BadgedTile(symbol: style.symbol, badge: nil, size: 36, tint: style.tint, soft: style.soft)
                    TextField("Name", text: $draftName)
                        .font(.title3.weight(.semibold))
                        .disabled(isOther)
                        .submitLabel(.done)
                        .onSubmit(rename)
                }
            } footer: {
                if isOther { Text("Other holds anything that fits no other category. It can’t be renamed or deleted.") }
            }

            Section("What goes here") {
                ForEach(category.includes) { line in
                    LineRow(line: line) { update(line, text: $0) }
                }
                .onDelete { remove(category.includes, at: $0) }
                HStack {
                    TextField("Add a line", text: $newInclude)
                        .onSubmit(addInclude)
                    Button("Add", systemImage: "plus.circle.fill", action: addInclude)
                        .labelStyle(.iconOnly)
                        .disabled(newInclude.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                ForEach(category.exclusions) { line in
                    VStack(alignment: .leading, spacing: 6) {
                        LineRow(line: line) { update(line, text: $0) }
                        Menu {
                            ForEach(targets, id: \.self) { target in
                                Button(target) { update(line, pointsTo: target) }
                            }
                        } label: {
                            Label(line.pointsTo ?? CategoryList.other, systemImage: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CategoryStyle.of(line.pointsTo ?? CategoryList.other).tint)
                        }
                    }
                }
                .onDelete { remove(category.exclusions, at: $0) }
                HStack {
                    TextField("Add a line", text: $newExclusion)
                        .onSubmit(addExclusion)
                    Picker("Goes to", selection: $newExclusionTarget) {
                        ForEach(targets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Not here")
            } footer: {
                Text("The on-device model follows these lines when it files a document. Dossier writes the Suggested lines. It never changes yours.")
            }

            Section {
                if category.builtIn != nil {
                    Button("Reset Lines", systemImage: "arrow.counterclockwise") {
                        CategoryList.update { $0.resetLines(for: category.name) }
                    }
                }
                if !isOther {
                    Button("Delete Category", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                }
            }
        }
        .confirmationDialog("Delete \(category.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) {
                CategoryList.update { $0.delete(category.name) }
                dismiss()
            }
        } message: {
            Text("Its documents are filed in your other categories. You can review the moves before they happen.")
        }
    }

    private func rename() {
        let new = CategoryList.clean(draftName)
        guard new != name else { return }
        var list = CategoryList.current
        if list.rename(name, to: new) {
            CategoryList.save(list)
            FieldRules.rename(name, to: new)
            name = new
        }
        draftName = name
    }

    private func update(_ line: FilingLine, text: String? = nil, pointsTo: String? = nil) {
        var lines = category?.lines ?? []
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        if let text {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard text != lines[index].text else { return }
            if text.isEmpty { lines.remove(at: index) } else { lines[index].text = text; lines[index].isYours = true }
        }
        if let pointsTo, lines.indices.contains(index) {
            lines[index].pointsTo = pointsTo
            lines[index].isYours = true
        }
        CategoryList.update { $0.setLines(lines, for: name) }
    }

    private func remove(_ shown: [FilingLine], at offsets: IndexSet) {
        let ids = Set(offsets.map { shown[$0].id })
        CategoryList.update { $0.setLines((category?.lines ?? []).filter { !ids.contains($0.id) }, for: name) }
    }

    private func addInclude() {
        let text = newInclude.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        CategoryList.update { $0.setLines((category?.lines ?? []) + [FilingLine(text: text, isYours: true)], for: name) }
        newInclude = ""
    }

    private func addExclusion() {
        let text = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, newExclusionTarget != name else { return }
        let line = FilingLine(text: text, pointsTo: newExclusionTarget, isYours: true)
        CategoryList.update { $0.setLines((category?.lines ?? []) + [line], for: name) }
        newExclusion = ""
    }
}

/// A filing line you can edit in place, marked Suggested or Yours.
private struct LineRow: View {
    let line: FilingLine
    let onCommit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("Line", text: $text, axis: .vertical)
                .onSubmit { onCommit(text) }
                .onChange(of: text) { _, new in
                    // A return ends the line, as the keyboard has no other way to finish a vertical field.
                    if new.contains("\n") { text = new.replacingOccurrences(of: "\n", with: ""); onCommit(text) }
                }
            Text(line.isYours ? "Yours" : "Suggested")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(line.isYours ? Color.orange.opacity(0.18) : Color.dsTint.opacity(0.14)))
                .foregroundStyle(line.isYours ? Color.orange : Color.dsTint)
        }
        .onAppear { text = line.text }
        .onChange(of: line.text) { _, new in text = new }
        .onDisappear { if text != line.text { onCommit(text) } }
    }
}

// MARK: Refile

/// After you change your categories: the documents that move, to review before anything moves.
struct RefileSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.dismiss) private var dismiss

    private var organizer: LibraryOrganizer { importer.organizer }

    var body: some View {
        NavigationStack {
            Group {
                if organizer.isCheckingRefile {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Checking your documents on this iPhone…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let moves = organizer.refileMoves {
                    List {
                        Section {
                            ForEach(moves) { move in
                                MoveRow(move: move)
                            }
                        } header: {
                            Text(moves.count == 1 ? "1 document moves" : "\(moves.count) documents move")
                        } footer: {
                            Text("Documents you moved yourself stay where they are. Their files in iCloud Drive › Dossier move too.")
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 8) {
                            Button {
                                Task {
                                    await organizer.applyRefile(context: modelContext)
                                    dismiss()
                                }
                            } label: {
                                Text(moves.count == 1 ? "Move 1 Document" : "Move \(moves.count) Documents").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("refile move")
                            Button("Keep Current Shelves") {
                                Task {
                                    await organizer.keepCurrentShelves(context: modelContext)
                                    dismiss()
                                }
                            }
                        }
                        .padding()
                        .background(.bar)
                    }
                }
            }
            .navigationTitle("Refile Documents")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(organizer.isCheckingRefile)
    }
}

private struct MoveRow: View {
    let move: RefileMove

    var body: some View {
        let to = CategoryStyle.of(move.to.category)
        HStack(spacing: 12) {
            BadgedTile(symbol: to.symbol, badge: nil, size: 32, tint: to.tint, soft: to.soft)
            VStack(alignment: .leading, spacing: 4) {
                Text(move.title).lineLimit(2)
                HStack(spacing: 6) {
                    chip(move.from ?? "Not filed", style: move.from.map(CategoryStyle.of))
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    chip("\(move.to.category) › \(move.to.folder)", style: to)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, style: CategoryStyle?) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(style?.soft ?? Color.secondary.opacity(0.15)))
            .foregroundStyle(style?.tint ?? Color.secondary)
    }
}

extension CategoryList {
    /// What decides where documents go: names and lines, not the order. A change here needs a refile.
    var filingSignature: String {
        categories.sorted { $0.name < $1.name }
            .map { c in c.name + "|" + c.lines.map { "\($0.text)>\($0.pointsTo ?? "")" }.sorted().joined(separator: ";") }
            .joined(separator: "\n")
    }
}
