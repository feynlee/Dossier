import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Forms tab: choose a fillable PDF, review which fields Dossier can fill, and save a filled copy.
struct FormsView: View {
    @State private var isPicking = false
    @State private var form: OpenedForm?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        WebFillStart()
                    } label: {
                        TileRow(symbol: "globe", badge: nil, title: "Fill a website", subtitle: "Visa, passport, travel and ID applications")
                    }
                    Button { isPicking = true } label: {
                        TileRow(symbol: "doc.badge.plus", badge: nil, title: "Fill a PDF form", subtitle: "USCIS forms, rental applications…")
                    }
                    .foregroundStyle(.primary)
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        BadgedTile(symbol: "doc.text", badge: nil, size: 56)
                        Text("Fill in forms")
                            .font(.title2.bold())
                        Text("Dossier fills what it knows from your documents: you, your family, where you’ve lived and your trips. You check everything before it’s entered, and you submit it yourself.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 12)
                } footer: {
                    Text("Only the form’s field labels are sent to Private Cloud Compute to match fields. Your values never are.")
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.dsWarning) }
                }
            }
            .navigationTitle("Forms")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.pdf]) { result in
                open(result)
            }
            .navigationDestination(item: $form) { form in
                FormFillView(form: form)
            }
        }
    }

    private func open(_ result: Result<URL, Error>) {
        errorMessage = nil
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
            errorMessage = "That PDF couldn’t be opened."
            return
        }
        let fields = FormFiller.fields(in: document)
        guard !fields.isEmpty else {
            errorMessage = "This PDF has no fillable fields. It may be a scanned form or an XFA form, which Dossier can’t fill."
            return
        }
        form = OpenedForm(name: url.deletingPathExtension().lastPathComponent, data: data, fields: fields)
    }
}

struct OpenedForm: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let data: Data
    let fields: [FormFieldInfo]
}
