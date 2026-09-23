import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Which fields Dossier will fill and with what, then a filled copy to save.
struct FormFillView: View {
    let form: OpenedForm

    @Query private var documents: [SourceDocument]
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var mapping: [String: FormValue] = [:]
    @State private var skipped: Set<String> = []
    @State private var isMatching = true
    @State private var filled: FilledPDF?
    @State private var isExporting = false
    @State private var errorMessage: String?

    @State private var book = FactBook(documents: [])

    private var matched: [FormFieldInfo] {
        form.fields.filter { field in mapping[field.name].map { book.has($0) } ?? false }
    }

    private var unmatched: [FormFieldInfo] {
        form.fields.filter { !matched.contains($0) }
    }

    private var fillCount: Int { matched.filter { !skipped.contains($0.name) }.count }

    var body: some View {
        List {
            Section {
                Text("\(matched.count) of \(form.fields.count) fields matched")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            if isMatching {
                Section { Label("Matching fields…", systemImage: "sparkles").foregroundStyle(.secondary) }
            }

            Section("Will be filled") {
                ForEach(matched) { field in
                    let value = mapping[field.name]!
                    Toggle(isOn: Binding(get: { !skipped.contains(field.name) }, set: { if $0 { skipped.remove(field.name) } else { skipped.insert(field.name) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.displayName).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            Text(preview(value, for: field))
                                .font(value.isSensitive || value.isDate ? .dsFieldValue : .body)
                        }
                    }
                }
            }

            if !unmatched.isEmpty {
                Section {
                    ForEach(unmatched) { field in
                        Text(field.displayName).foregroundStyle(.secondary).lineLimit(2)
                    }
                } header: {
                    Text("Left for you")
                } footer: {
                    Text("Dossier doesn’t answer eligibility questions, signatures or fields about other people.")
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

    private func preview(_ value: FormValue, for field: FormFieldInfo) -> String {
        if value.isSensitive, let fact = book.fact(for: value) { return VaultReader.masked(fact) }
        return book.string(for: value, dateStyle: FormDateStyle.style(for: field), context: nil) ?? "—"
    }

    private func match() async {
        book = FactBook(documents: documents)
        var result: [String: FormValue] = [:]
        for field in form.fields {
            if let value = FormFieldMatcher.match(field) { result[field.name] = value }
        }
        mapping = result
        let rest = form.fields.filter { result[$0.name] == nil }
        let suggested = await FormFieldAssistant().suggest(for: rest, preferPrivateCloud: usePrivateCloud)
        mapping.merge(suggested) { current, _ in current }
        isMatching = false
    }

    private func fill() {
        Task {
            do {
                let fields = matched.filter { !skipped.contains($0.name) }
                let needsFaceID = fields.contains { mapping[$0.name]?.isSensitive == true }
                let context = needsFaceID ? try await Authenticator.authenticate(reason: "Fill document numbers into the form") : nil
                var values: [String: String] = [:]
                for field in fields {
                    guard let value = mapping[field.name] else { continue }
                    values[field.name] = book.string(for: value, dateStyle: FormDateStyle.style(for: field), context: context)
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
