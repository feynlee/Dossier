import SwiftData
import SwiftUI

/// The Personal tab: your details compiled from all your documents, each value in full, ready to copy. The
/// source beside a value opens the document it comes from.
struct PersonalView: View {
    @Query private var documents: [SourceDocument]
    @State private var path: [PersonalRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ProfileView(title: "Personal", subtitle: "From your documents. Tap a value to copy it.") { document, fact in
                path.append(PersonalRoute(document: document.persistentModelID, fact: fact?.persistentModelID))
            }
            .overlay {
                if documents.isEmpty {
                    ContentUnavailableView {
                        Label("No details yet", systemImage: "person.crop.circle")
                    } description: {
                        Text("Add documents in the Vault. Your name, numbers and address appear here.")
                    }
                }
            }
            .navigationDestination(for: PersonalRoute.self) { route in
                if let document = documents.first(where: { $0.persistentModelID == route.document }) {
                    DocumentDetailView(document: document, focus: route.fact)
                } else {
                    ContentUnavailableView("Document removed", systemImage: "doc")
                }
            }
        }
    }
}

/// A document opened from the Personal tab, on the field a value comes from when there is one.
struct PersonalRoute: Hashable {
    var document: PersistentIdentifier
    var fact: PersistentIdentifier?
}
