import SwiftData
import SwiftUI

/// Settings › Library › Key documents: the stack at the top of the Vault. IDs in use join on their own; you
/// can reorder the stack, take a document out and pin another one. Payment, loyalty and insurance cards
/// never join on their own: Dossier holds documents, not a second Apple Wallet.
struct KeyDocumentsSettingsView: View {
    @AppStorage(KeyDocuments.storageKey) private var json = ""
    @Query private var documents: [SourceDocument]

    private var keys: KeyDocuments { KeyDocuments(json: json) }

    /// The stack, top of the screen first.
    private var stack: [SourceDocument] {
        WalletStack.cards(documents.filter { !$0.isGone }, keys: keys, status: { $0.lifecycleStatus })
    }

    var body: some View {
        let stack = self.stack
        List {
            Section {
                if stack.isEmpty {
                    Text("No key documents yet. Passports, licences, IDs, green cards, EAD cards and visas join on their own.")
                        .foregroundStyle(.secondary)
                }
                ForEach(stack) { document in
                    KeyDocumentRow(document: document, isPinned: keys.pinned.contains(document.contentHash))
                }
                .onMove { source, destination in
                    var hashes = stack.map(\.contentHash)
                    hashes.move(fromOffsets: source, toOffset: destination)
                    KeyDocuments.update { $0.reorder(hashes) }
                }
                .onDelete { offsets in
                    let removed = offsets.map { stack[$0] }
                    KeyDocuments.update { keys in removed.forEach { keys.remove($0.contentHash, kind: $0.kind) } }
                }
                NavigationLink {
                    PinDocumentView(excluded: Set(stack.map(\.contentHash)))
                } label: {
                    Label("Pin Another Document", systemImage: "pin")
                }
                .accessibilityIdentifier("pin key document")
            } header: {
                Text("In the stack")
            } footer: {
                Text("The documents that prove who you are and your status, at the top of the Vault and ready to copy into a form. Tap Edit to reorder. Passports, licences, IDs, green cards, EAD cards and visas join on their own while they’re in use.")
            }

            Section {
            } footer: {
                Text("Payment, loyalty and insurance cards stay out of the stack. Keep payment cards in Apple Wallet. Insurance cards stay on the Insurance shelf.")
            }
        }
        .navigationTitle("Key Documents")
        .toolbar { EditButton() }
    }
}

private struct KeyDocumentRow: View {
    let document: SourceDocument
    let isPinned: Bool

    var body: some View {
        let style = CategoryStyle.of(document.libraryCategory ?? CategoryList.other)
        HStack(spacing: 12) {
            BadgedTile(symbol: document.kind.symbol, badge: nil, size: 32, tint: style.tint, soft: style.soft)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(document.kind == .other ? document.title : document.kind.displayName)
                    if isPinned {
                        Text("Pinned")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let person = document.libraryPerson { parts.append(person) }
        if let expiry = document.expiryDate { parts.append("until \(SimpleDate(utc: expiry).display)") }
        return parts.joined(separator: " · ")
    }
}

/// Picks a document to pin to the stack, grouped by category.
private struct PinDocumentView: View {
    let excluded: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Query private var documents: [SourceDocument]
    @State private var search = ""

    private var candidates: [(category: String, documents: [SourceDocument])] {
        let list = CategoryList.current
        let shown = documents.filter { document in
            guard document.isReady, !document.isGone, !excluded.contains(document.contentHash) else { return false }
            guard !search.isEmpty else { return true }
            return (document.libraryName ?? document.title).localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: shown) { $0.libraryCategory.map { list.resolve($0) ?? $0 } ?? CategoryList.other }
        return grouped.map { ($0.key, $0.value.sorted { ($0.libraryName ?? $0.title) < ($1.libraryName ?? $1.title) }) }
            .sorted { list.order(of: $0.category) < list.order(of: $1.category) }
    }

    var body: some View {
        List {
            ForEach(candidates, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.documents) { document in
                        Button {
                            KeyDocuments.update { $0.add(document.contentHash) }
                            dismiss()
                        } label: {
                            Text(document.libraryName ?? document.title).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Pin a Document")
        .navigationBarTitleDisplayMode(.inline)
    }
}
