import SwiftData
import SwiftUI

extension View {
    /// Asks before reading documents again, then queues them.
    func rereadDocuments(_ documents: Binding<[SourceDocument]>, onReread: @escaping () -> Void = {}) -> some View {
        modifier(RereadDocumentsModifier(documents: documents, onReread: onReread))
    }

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
        if documents.count == 1 { return "Remove “\(documents[0].title)”?" }
        return removesEverything ? "Remove all \(documents.count) documents?" : "Remove \(documents.count) documents?"
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

private struct RereadDocumentsModifier: ViewModifier {
    @Binding var documents: [SourceDocument]
    let onReread: () -> Void

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true

    func body(content: Content) -> some View {
        content.confirmationDialog(
            documents.count == 1 ? "Read “\(documents.first?.title ?? "")” again?" : "Read \(documents.count) documents again?",
            isPresented: Binding(get: { !documents.isEmpty }, set: { if !$0 { documents = [] } }),
            titleVisibility: .visible
        ) {
            Button("Read Again") {
                importer.reread(documents, context: modelContext, preferPrivateCloud: usePrivateCloud)
                documents = []
                onReread()
            }
        } message: {
            Text("Each file is read again and what Dossier read before is replaced. Fields you confirmed will need confirming again. Your edits to personal information stay.")
        }
    }
}

/// The vault before anything is added, or after everything was removed.
struct EmptyVault: View {
    @Binding var isPickingFiles: Bool
    @Binding var isPickingFolder: Bool
    @Binding var isScanning: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Add your documents", systemImage: "doc.badge.plus")
        } description: {
            Text("Scan your passport, green card, visa, lease or travel records with the camera, or choose files from iCloud Drive. Dossier reads only what you add and never changes your files.")
        } actions: {
            Button("Scan Documents", systemImage: "doc.viewfinder") { isScanning = true }
                .buttonStyle(.borderedProminent)
            Button("Choose Files", systemImage: "doc") { isPickingFiles = true }
            Button("Choose from a Folder", systemImage: "folder") { isPickingFolder = true }
        }
        .tint(.dsTint)
    }
}

/// The Add menu: each way to add documents, with a line on how it works, so picking several files is easy
/// to find.
struct AddDocumentsMenuItems: View {
    @Binding var isPickingFiles: Bool
    @Binding var isPickingFolder: Bool
    @Binding var isScanning: Bool

    var body: some View {
        Button { isScanning = true } label: {
            Label {
                Text("Scan Documents")
                Text("Use the camera")
            } icon: { Image(systemName: "doc.viewfinder") }
        }
        Button { isPickingFiles = true } label: {
            Label {
                Text("Choose Files")
                Text("Tap a file to add it, or Select for several")
            } icon: { Image(systemName: "doc") }
        }
        Button { isPickingFolder = true } label: {
            Label {
                Text("Choose from a Folder")
                Text("Tick files across its subfolders")
            } icon: { Image(systemName: "folder") }
        }
    }
}
