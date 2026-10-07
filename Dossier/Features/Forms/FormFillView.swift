import LocalAuthentication
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Which fields Dossier will fill and with what, then a filled copy to save.
struct FormFillView: View {
    let form: OpenedForm

    @Query private var documents: [SourceDocument]
    @Query private var overrides: [ProfileOverride]
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var catalog = FormCatalog(entries: [])
    @State private var assignment = FormAssignment(entries: [:], matches: [:], remaining: [:])
    @State private var skipped: Set<String> = []
    @State private var isMatching = true
    @State private var filled: FilledPDF?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private var fields: [FieldDescriptor] { form.fields.map(\.descriptor) }

    private var matched: [FieldDescriptor] { fields.filter { assignment.entries[$0.id] != nil } }
    private var unmatched: [FieldDescriptor] { fields.filter { assignment.entries[$0.id] == nil } }
    private var fillCount: Int { matched.filter { !skipped.contains($0.id) }.count }

    var body: some View {
        List {
            if isMatching {
                Section { Label("Matching fields…", systemImage: "sparkles").foregroundStyle(.secondary) }
            }

            Section("\(matched.count) of \(fields.count) fields matched") {
                ForEach(matched) { field in
                    let entry = assignment.entries[field.id].flatMap(catalog.entry)
                    Toggle(isOn: Binding(get: { !skipped.contains(field.id) }, set: { if $0 { skipped.remove(field.id) } else { skipped.insert(field.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            Text(preview(field))
                                .font(entry?.isSensitive == true || entry?.kind == .date ? .dsFieldValue : .body)
                        }
                    }
                }
            }

            if !assignment.remaining.isEmpty {
                Section {
                    ForEach(assignment.remaining.sorted { $0.key < $1.key }, id: \.key) { name, count in
                        Label("\(count) more \(name.lowercased()) than this form has room for", systemImage: "rectangle.stack.badge.plus")
                    }
                } footer: {
                    Text("Forms usually have a continuation sheet for these.")
                }
            }

            if !unmatched.isEmpty {
                Section {
                    ForEach(unmatched) { field in
                        Text(field.label).foregroundStyle(.secondary).lineLimit(2)
                    }
                } header: {
                    Text("Left for you")
                } footer: {
                    Text("Dossier doesn’t answer eligibility questions or signatures.")
                }
            }
        }
        .navigationTitle(form.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button(action: fill) {
                    Text("Fill \(fillCount) fields").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(fillCount == 0 || isMatching)
                Text("Saves a copy. The original file isn’t changed.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)
        }
        .task { await match() }
        .fileExporter(isPresented: $isExporting, document: filled, contentType: .pdf, defaultFilename: "\(form.name) (filled)") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("Couldn’t fill the form", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func preview(_ field: FieldDescriptor) -> String {
        guard let entry = assignment.entries[field.id].flatMap(catalog.entry) else { return "—" }
        if entry.isSensitive { return entry.masked ?? "•••• ••" }
        return text(for: field, context: nil) ?? "—"
    }

    private func text(for field: FieldDescriptor, context: LAContext?) -> String? {
        guard let entry = assignment.entries[field.id].flatMap(catalog.entry), let value = catalog.value(of: entry, context: context) else { return nil }
        return FormMatcher.candidates(for: value, kind: entry.kind, part: assignment.matches[field.id]?.part, field: field).first
    }

    private func match() async {
        catalog = FormCatalog.build(documents: documents, overrides: overrides)
        let slots = Set(catalog.slots.map(\.slot))
        var matches: [String: FieldMatch] = [:]
        for field in fields {
            if let match = FormMatcher.match(field, slots: slots) { matches[field.id] = match }
        }
        assignment = FormMatcher.assign(fields, matches: matches, catalog: catalog)
        let rest = fields.filter { matches[$0.id] == nil }
        let suggested = await FieldAssistant().suggest(for: rest, slots: catalog.slots, preferPrivateCloud: usePrivateCloud)
        matches.merge(suggested) { current, _ in current }
        assignment = FormMatcher.assign(fields, matches: matches, catalog: catalog)
        isMatching = false
    }

    private func fill() {
        Task {
            do {
                let chosen = matched.filter { !skipped.contains($0.id) }
                let needsFaceID = catalog.needsFaceID(chosen.compactMap { assignment.entries[$0.id] })
                let context = needsFaceID ? try await Authenticator.authenticate(reason: "Fill document numbers into the form") : nil
                var values: [String: String] = [:]
                for field in chosen {
                    values[field.id] = text(for: field, context: context)
                }
                guard let document = PDFDocument(data: form.data), let data = FormFiller.fill(document, values: values) else {
                    errorMessage = "The filled PDF couldn’t be created."
                    return
                }
                filled = FilledPDF(data: data)
                isExporting = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A filled PDF for the save sheet.
struct FilledPDF: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
