import SwiftData
import SwiftUI

/// One Key document brought forward: the card big at the top, every field to copy, a way to the
/// document's page, and the other Key documents below to switch to.
struct WalletFocusView: View {
    /// Every Key document, back to front, as the wallet shows them.
    let cards: [SourceDocument]
    /// Called after the sheet closes, to open the document's page.
    let onOpen: (SourceDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var focused: SourceDocument
    /// The field just copied: it reads "Copied" for a moment.
    @State private var copied: PersistentIdentifier?

    private static let miniHeight: CGFloat = 56
    private static let miniPeek: CGFloat = 40

    init(document: SourceDocument, cards: [SourceDocument], onOpen: @escaping (SourceDocument) -> Void) {
        self.cards = cards
        self.onOpen = onOpen
        _focused = State(initialValue: document)
    }

    /// The fields that have a value, in the document's order.
    private var fields: [(fact: Fact, value: String)] {
        focused.facts
            .filter { $0.status != .superseded }
            .sorted { ($0.key.sortOrder, $0.position) < ($1.key.sortOrder, $1.position) }
            .compactMap { fact in VaultReader.cardValue(fact).map { (fact, VaultReader.display($0, for: fact.key)) } }
    }

    private var others: [SourceDocument] {
        cards.filter { $0.persistentModelID != focused.persistentModelID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WalletCard(document: focused, isFront: true)
                        .frame(height: WalletStack.cardHeight)
                        .id(focused.persistentModelID)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                Section {
                    if fields.isEmpty {
                        Text("No fields read from this document yet.").foregroundStyle(.secondary)
                    }
                    ForEach(fields, id: \.fact.persistentModelID) { field in
                        fieldRow(field.fact, value: field.value)
                    }
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Tap a field to copy it.")
                }

                Section {
                    Button("Open document", systemImage: "doc.text") {
                        let document = focused
                        dismiss()
                        onOpen(document)
                    }
                    .accessibilityIdentifier("open document")
                }

                if !others.isEmpty {
                    Section("Other key documents") {
                        otherCards
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .navigationTitle(focused.kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func fieldRow(_ fact: Fact, value: String) -> some View {
        let isCopied = copied == fact.persistentModelID
        return Button {
            VaultReader.copy(value, sensitive: fact.isSensitive)
            withAnimation(.snappy) { copied = fact.persistentModelID }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copied == fact.persistentModelID { withAnimation(.snappy) { copied = nil } }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if isCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.dsTint)
                } else {
                    Text(fact.displayLabel).font(.footnote).foregroundStyle(.secondary)
                }
                Text(value)
                    .font(fact.isSensitive ? .dsFieldValue : .body)
                    .foregroundStyle(.primary)
                    .textSelection(.disabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCopied ? Color.dsTintSoft : nil)
        .accessibilityLabel(isCopied ? "\(fact.displayLabel) copied" : "\(fact.displayLabel), \(value)")
        .accessibilityHint("Copies the value.")
    }

    /// The other Key documents as a small stack; tapping one brings it forward.
    private var otherCards: some View {
        let others = self.others
        return ZStack(alignment: .top) {
            ForEach(Array(others.enumerated()), id: \.element.persistentModelID) { index, document in
                Button {
                    withAnimation(.snappy) {
                        focused = document
                        copied = nil
                    }
                } label: {
                    WalletCard(document: document, isFront: false)
                        .frame(height: Self.miniHeight)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("key document \(document.libraryName ?? document.title)")
                .offset(y: CGFloat(index) * Self.miniPeek)
            }
        }
        .frame(height: Self.miniHeight + CGFloat(max(others.count - 1, 0)) * Self.miniPeek, alignment: .top)
    }
}
