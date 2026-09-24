import SwiftData
import SwiftUI

extension View {
    /// Asks before removing documents from the vault, then removes them. Removing every document also removes
    /// your edits and the encryption keys, like "Remove all documents" in Settings.
    /// Pass `leavingScreen` from a screen that shows the document, so it closes before the document goes.
    func removeDocuments(_ documents: Binding<[SourceDocument]>, leavingScreen: Bool = false, onRemove: @escaping () -> Void = {}) -> some View {
        modifier(RemoveDocumentsModifier(documents: documents, leavingScreen: leavingScreen, onRemove: onRemove))
    }
}

private struct RemoveDocumentsModifier: ViewModifier {
    @Binding var documents: [SourceDocument]
    let leavingScreen: Bool
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var all: [SourceDocument]

    private var removesEverything: Bool { !all.isEmpty && documents.count >= all.count }

    private var title: String {
        documents.count == 1 ? "Remove “\(documents[0].title)”?" : "Remove \(documents.count) documents?"
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { !documents.isEmpty }, set: { if !$0 { documents = [] } }),
            titleVisibility: .visible
        ) {
            Button(documents.count == 1 ? "Remove Document" : "Remove \(documents.count) Documents", role: .destructive) {
                let removed = documents
                let everything = removesEverything
                documents = []
                if leavingScreen {
                    dismiss()
                    Task {
                        // Let the screen close first, so it never shows a removed document.
                        try? await Task.sleep(for: .milliseconds(500))
                        remove(removed, everything: everything)
                    }
                } else {
                    remove(removed, everything: everything)
                }
            }
        } message: {
            Text(removesEverything
                ? "Dossier forgets everything it read, your edits and your timeline. Your files aren’t deleted, so you can add them again."
                : "Dossier forgets what it read from \(documents.count == 1 ? "this file" : "these files"). The \(documents.count == 1 ? "file isn’t" : "files aren’t") deleted, so you can add \(documents.count == 1 ? "it" : "them") again.")
        }
    }

    private func remove(_ removed: [SourceDocument], everything: Bool) {
        if everything {
            importer.removeAll(context: modelContext)
        } else {
            importer.remove(removed, context: modelContext, preferPrivateCloud: usePrivateCloud)
        }
        onRemove()
    }
}

/// The vault before anything is added, or after everything was removed.
struct EmptyVault: View {
    @Binding var isPickingFiles: Bool
    @Binding var isPickingFolder: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Add your documents", systemImage: "doc.badge.plus")
        } description: {
            Text("Passport, green card, visa, lease or travel records. Dossier reads only the files you add and never changes them.")
        } actions: {
            Button("Add Documents") { isPickingFiles = true }
                .buttonStyle(.borderedProminent)
            Button("Choose from a Folder") { isPickingFolder = true }
        }
        .tint(.dsTint)
    }
}
