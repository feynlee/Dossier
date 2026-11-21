import SwiftData
import SwiftUI

/// Read Again for one or more documents: shows the fields each is read with now, and lets you keep them,
/// choose your own fields, use the category rule, or go back to the default.
struct ReadAgainSheet: View {
    let documents: [SourceDocument]
    var onReread: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var all: [SourceDocument]
    @State private var included: Set<PersistentIdentifier> = []
    @State private var choice = Choice.same
    @State private var ownFields: ReadingFields?
    @State private var isEditing = false

    enum Choice: Hashable { case same, own, categoryRule, standard }

    private var chosen: [SourceDocument] { documents.filter { included.contains($0.persistentModelID) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(documents) { document in
                        Button { toggle(document) } label: { row(document) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("Fields now")
                }

                Section {
                    option(.same, "The same as now", "Each file keeps its own fields, rule or default")
                    Button {
                        isEditing = true
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            radio(.own)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Choose your own fields").foregroundStyle(.primary)
                                Text(ownFields.map { $0.fields.isEmpty ? "No fields: only what Dossier reads by default" : $0.summary }
                                    ?? "Name the fields to read, with suggestions for each kind. They replace each file’s current fields.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    option(.categoryRule, "Category rule", ruleSubtitle)
                    option(.standard, "Default", "What Dossier thinks is important. Removes own fields and rules")
                } header: {
                    Text("Use")
                } footer: {
                    Text("\(documents.count > 1 ? "Uncheck a file to leave it out. " : "")Facts you confirmed will need confirming again. Your edits to personal information stay.")
                }
            }
            .navigationTitle("Read Again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    read()
                } label: {
                    Text(chosen.count == 1 ? "Read Again" : "Read \(chosen.count) Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.dsTint)
                .disabled(chosen.isEmpty || (choice == .own && ownFields == nil))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .sheet(isPresented: $isEditing) {
                FieldEditor(
                    subtitle: chosen.count == 1 ? "Fields for 1 File" : "Fields for \(chosen.count) Files",
                    kinds: chosen.map(\.kind),
                    category: Set(chosen.compactMap(\.ruleCategory)).count == 1 ? chosen.first?.ruleCategory : nil,
                    fields: ownFields ?? commonOwnFields ?? ReadingFields(),
                    usedBefore: FieldRules.usedBefore(in: all),
                    offersRule: false
                ) { fields, _ in
                    ownFields = fields
                    choice = .own
                }
            }
            .onAppear { included = Set(documents.map(\.persistentModelID)) }
        }
    }

    /// The fields the chosen files share, to start editing from.
    private var commonOwnFields: ReadingFields? {
        let own = chosen.compactMap(\.ownFields)
        guard own.count == chosen.count, let first = own.first, own.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private var ruleSubtitle: String {
        let rules = Set(chosen.compactMap { FieldRules.rule(for: $0.ruleCategory) != nil ? $0.ruleCategory : nil })
        if rules.count == 1, let category = rules.first, let rule = FieldRules.rule(for: category) {
            return "\(category): \(rule.summary.isEmpty ? "only the standard facts" : rule.summary). Removes each file’s own fields"
        }
        return "Removes each file’s own fields. Files in a category without a rule use the default"
    }

    private func row(_ document: SourceDocument) -> some View {
        HStack(spacing: 12) {
            if documents.count > 1 {
                Image(systemName: included.contains(document.persistentModelID) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(included.contains(document.persistentModelID) ? Color.dsTint : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).lineLimit(1)
                FieldTag(document.fieldSource)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func option(_ value: Choice, _ title: String, _ subtitle: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                radio(value)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == value ? .isSelected : [])
    }

    private func radio(_ value: Choice) -> some View {
        Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
            .font(.title3)
            .foregroundStyle(choice == value ? Color.dsTint : Color.secondary)
    }

    private func toggle(_ document: SourceDocument) {
        guard documents.count > 1 else { return }
        let id = document.persistentModelID
        if included.contains(id) { included.remove(id) } else { included.insert(id) }
    }

    private func read() {
        let fields: ImportCoordinator.FieldChoice = switch choice {
        case .same: .same
        case .own: ownFields.map { ImportCoordinator.FieldChoice.own($0) } ?? .same
        case .categoryRule: .categoryRule
        case .standard: .standard
        }
        importer.reread(chosen, fields: fields, context: modelContext, preferPrivateCloud: usePrivateCloud)
        onReread()
        dismiss()
    }
}

extension View {
    /// Read Again with a choice of fields, for the documents set.
    func readAgainSheet(_ documents: Binding<[SourceDocument]>, onReread: @escaping () -> Void = {}) -> some View {
        sheet(isPresented: Binding(get: { !documents.wrappedValue.isEmpty }, set: { if !$0 { documents.wrappedValue = [] } })) {
            ReadAgainSheet(documents: documents.wrappedValue, onReread: onReread)
        }
    }
}
