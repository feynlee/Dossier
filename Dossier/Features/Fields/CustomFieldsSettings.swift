import SwiftData
import SwiftUI

/// Settings › Custom fields: whether to ask for fields when adding files, and a standing rule per category.
struct CustomFieldsSettingsView: View {
    @AppStorage(FieldRules.askWhenAddingKey) private var asksWhenAdding = true
    @State private var rules: [String: ReadingFields] = [:]

    @AppStorage(CategoryList.storageKey) private var categoryJSON = ""

    /// Your categories, then any others that have a rule.
    private var categories: [String] {
        let list = CategoryList(json: categoryJSON)
        return list.names + rules.keys.filter { list.resolve($0) == nil }.sorted()
    }

    var body: some View {
        List {
            Section {
                Toggle("Ask when adding files", isOn: $asksWhenAdding)
                    .tint(Color.dsTintFill)
            } footer: {
                Text("Shows the files before they’re read, so you can ask for specific fields. Off: files are read right away with their category’s rule or the default.")
            }

            Section {
                ForEach(categories, id: \.self) { category in
                    NavigationLink {
                        CategoryRuleView(category: category)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category)
                            Text(subtitle(for: category))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("Category rules")
            } footer: {
                Text("A category rule is one set of fields for every file Dossier puts in that category, unless the file has fields of its own.")
            }

            Section {
                LabeledContent("Standard facts and useful details", value: "Always")
            } header: {
                Text("Default")
            } footer: {
                Text("For files with no fields of their own and no category rule, Dossier reads what it thinks is important: each kind’s standard facts, plus anything else it finds useful. Family and other details, and Also look for, are in Settings › Reading.")
            }
        }
        .navigationTitle("Custom fields")
        .onAppear { rules = FieldRules.all }
    }

    private func subtitle(for category: String) -> String {
        guard let rule = rules[category] else { return "No rule: the default" }
        let names = rule.fields.isEmpty ? "Only the standard facts" : rule.summary
        return rule.readsUseful ? "\(names), and anything else useful" : names
    }
}

/// One category's rule: its fields, and whether Dossier also reads anything else useful. Saving offers to
/// read the files that use it again.
struct CategoryRuleView: View {
    let category: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var documents: [SourceDocument]
    @State private var fields = ReadingFields()
    @State private var newName = ""
    @State private var saved = false
    @State private var dismissedOffer = false

    /// Files in this category that would be read with the rule: those without fields of their own.
    private var affected: [SourceDocument] {
        let list = CategoryList.current
        return documents.filter { $0.ruleCategory.flatMap { list.resolve($0) } == category && $0.ownFields == nil && $0.bookmark != nil && $0.isReady }
    }

    private var suggestions: [String] {
        let kind: DocumentKind = CategoryList.current.builtIn("Home") == category ? .lease : .other
        return FieldRules.suggestions(for: kind, category: category)
            .filter { name in !fields.fields.contains { $0.id == name.lowercased() } }
    }

    var body: some View {
        List {
            Section {
                ForEach($fields.fields) { $field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.name)
                        TextField("Hint (optional)", text: $field.hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { fields.fields.remove(atOffsets: $0); saved = false }
                .onMove { fields.fields.move(fromOffsets: $0, toOffset: $1); saved = false }
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.dsTint)
                    TextField("Add a field", text: $newName)
                        .submitLabel(.done)
                        .onSubmit { add(newName) }
                }
            } header: {
                Text("Fields for \(category.lowercased()) documents")
            } footer: {
                Text("Covers every file Dossier puts under \(category), unless it has fields of its own.")
            }

            if !suggestions.isEmpty {
                Section("Suggested") {
                    FlowLayout {
                        ForEach(suggestions, id: \.self) { name in
                            Button {
                                add(name)
                            } label: {
                                Label(name, systemImage: "plus")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .overlay(Capsule().strokeBorder(Color(uiColor: .separator)))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.dsTint)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }

            Section {
                Toggle(isOn: $fields.readsUseful) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also read anything else useful")
                        Text("Off: only these fields and each kind’s standard facts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.dsTintFill)
                .onChange(of: fields.readsUseful) { saved = false }
            }

            if saved, !dismissedOffer, !affected.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(affected.count == 1 ? "Read 1 \(category.lowercased()) document again?" : "Read \(affected.count) \(category.lowercased()) documents again?")
                            .font(.headline)
                        Text("So they include what you asked for. Your edits stay.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button("Read Again", systemImage: "arrow.clockwise") {
                        importer.reread(affected, context: modelContext, preferPrivateCloud: usePrivateCloud)
                        dismissedOffer = true
                    }
                    .disabled(importer.isRunning)
                    Button("Not Now") { dismissedOffer = true }
                }
            }

            if FieldRules.rule(for: category) != nil {
                Section {
                    Button("Delete Rule", role: .destructive) {
                        FieldRules.set(nil, for: category)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    add(newName)
                    FieldRules.set(fields, for: category)
                    saved = true
                    dismissedOffer = false
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear { fields = FieldRules.rule(for: category) ?? ReadingFields() }
    }

    private func add(_ name: String) {
        newName = ""
        if withAnimation(.default, { fields.add(name) }) { saved = false }
    }
}
