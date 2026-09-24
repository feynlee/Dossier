import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Adding documents: the Files picker, where you can open any folder (iCloud Drive included) and select
/// several files at once. Only the files you add are read.
struct AddDocumentsModifier: ViewModifier {
    @Binding var isPicking: Bool
    var onAdded: () -> Void = {}

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPicking, allowedContentTypes: FileAccess.readableTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    if importer.add(urls, context: modelContext, preferPrivateCloud: usePrivateCloud) > 0 { onAdded() }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Couldn’t add documents", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

extension View {
    func addDocuments(isPresented: Binding<Bool>, onAdded: @escaping () -> Void = {}) -> some View {
        modifier(AddDocumentsModifier(isPicking: isPresented, onAdded: onAdded))
    }
}
