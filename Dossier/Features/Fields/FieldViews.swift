import SwiftUI

/// The tag that says which fields a file is read with: filled for your fields or a category rule, outlined
/// for the default.
struct FieldTag: View {
    let text: String
    var filled: Bool

    init(_ text: String, filled: Bool) {
        self.text = text
        self.filled = filled
    }

    init(_ source: FieldSource, short: Bool = false) {
        self.text = short ? source.shortTag : source.tag
        self.filled = !source.isStandard
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(filled ? Color.primary : Color.secondary)
            .lineLimit(2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: 6).fill(Color.dsTintSoft)
                } else {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(uiColor: .separator))
                }
            }
    }
}

/// Lays out views left to right, wrapping onto new lines: suggestion chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Edits a set of fields: the names you want read, each with an optional hint, whether Dossier also reads
/// anything else useful, and (when adding files) whether to keep them as a category rule.
struct FieldEditor: View {
    /// Shown under the title, such as the files the fields are for.
    let subtitle: String
    /// The kinds of the files, for the standard facts shown in gray and the suggestions. Empty when unknown.
    let kinds: [DocumentKind]
    let category: String?
    @State var fields: ReadingFields
    let usedBefore: [String]
    /// Offers "Also for future" files in a category; nil hides it.
    var offersRule: Bool = true
    let onDone: (_ fields: ReadingFields, _ ruleCategory: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var ruleCategory: String?
    @FocusState private var isAdding: Bool

    private var kindName: String {
        guard let kind = kinds.first, kinds.allSatisfy({ $0 == kind }), kind != .other else { return "these files" }
        return LibraryNaming.rule(for: kind)?.folder.lowercased() ?? "\(kind.displayName.lowercased())s"
    }

    private var standardNames: [String] {
        var names: [String] = []
        for kind in kinds {
            for name in FieldRules.standardFieldNames(for: kind) where !names.contains(name) { names.append(name) }
        }
        return names
    }

    private var suggestions: [String] {
        var names: [String] = []
        let kind = kinds.first ?? .other
        for name in FieldRules.suggestions(for: kind, category: category) + usedBefore
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            && !fields.fields.contains(where: { $0.id == name.lowercased() }) {
            names.append(name)
        }
        return Array(names.prefix(10))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !standardNames.isEmpty || fields.fields.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(standardNames.isEmpty ? "Read by default" : "Always read for \(kindName)")
                                .font(.footnote)
                            ForEach(standardNames, id: \.self) { Text($0) }
                            if fields.readsUseful {
                                Text(standardNames.isEmpty ? "What Dossier thinks is important" : "plus anything else Dossier finds useful")
                                    .font(.subheadline)
                                    .padding(.top, 2)
                            }
                        }
                        .foregroundStyle(.tertiary)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach($fields.fields) { $field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.name)
                            TextField("Hint (optional), like yes, no, or the conditions", text: $field.hint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { fields.fields.remove(atOffsets: $0) }
                    .onMove { fields.fields.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.dsTint)
                        TextField("Add a field", text: $newName)
                            .focused($isAdding)
                            .submitLabel(.done)
                            .onSubmit { add(newName) }
                    }
                } header: {
                    Text("Your fields")
                } footer: {
                    Text("The gray text is what Dossier reads if you add nothing. Each field you add gets its own row in the document, with where it was found, or “Not found”.")
                }

                if !suggestions.isEmpty {
                    Section {
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
                    } header: {
                        Text(kinds.isEmpty || kindName == "these files" ? "Suggested" : "Suggested for \(kindName)")
                    } footer: {
                        Text("Common fields\(kindName == "these files" ? "" : " for \(kindName)"), plus ones you’ve used before.")
                    }
                }

                Section {
                    Toggle(isOn: $fields.readsUseful) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also read anything else useful")
                            Text("What Dossier thinks is important. Off: only the fields in the box above.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Color.dsTintFill)
                }

                if offersRule {
                    Section {
                        Picker("Also for future", selection: $ruleCategory) {
                            Text("None").tag(String?.none)
                            ForEach(LibraryNaming.starterCategories, id: \.self) { Text("\($0) files").tag(Optional($0)) }
                        }
                    } footer: {
                        Text("Keeps these fields as a rule for files Dossier puts in that category. Change rules in Settings › Custom fields.")
                    }
                }
            }
            .navigationTitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        add(newName)
                        onDone(fields, ruleCategory)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func add(_ name: String) {
        newName = ""
        _ = withAnimation { fields.add(name) }
    }
}
