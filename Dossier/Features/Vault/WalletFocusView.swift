import SwiftData
import SwiftUI

/// A Key document brought forward, like a card in Apple Wallet. The cards are drawn on top of the Vault where
/// the stack has them; then the tapped card rises to the top, the cards above it leave over the top edge, and
/// the cards below it drop to a small stack at the bottom. Its fields show under it. Done puts every card back.
struct WalletFocusOverlay: View {
    /// Every Key document, top of the screen first, as the stack shows them.
    let cards: [SourceDocument]
    /// Where each card is in the stack, in global coordinates, by content hash.
    let stackFrames: [String: CGRect]
    @Binding var focused: SourceDocument?
    /// Called after the cards are back in the stack, to open the document's page.
    let onOpen: (SourceDocument) -> Void

    /// False while the cards sit where the stack has them; true once the tapped card is forward.
    @State private var isForward = false
    /// The field just copied: it reads "Copied" for a moment.
    @State private var copied: PersistentIdentifier?

    private static let barHeight: CGFloat = 52
    private static let restPeek: CGFloat = 18
    private static let restHeight: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            // Local coordinates start under the status bar; the stack's frames are global.
            let origin = geometry.frame(in: .global).origin
            let size = geometry.size
            let top = Self.barHeight
            ZStack(alignment: .topLeading) {
                Color(.systemGroupedBackground)
                    .opacity(isForward ? 1 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                if let focused {
                    details(for: focused, top: top + WalletStack.cardHeight + 16, bottom: restTop(size: size) - 12, width: size.width)
                        .opacity(isForward ? 1 : 0)
                }

                ForEach(Array(cards.enumerated()), id: \.element.persistentModelID) { index, card in
                    let frame = place(card, index: index, size: size, origin: origin, top: top)
                    Button { select(card) } label: {
                        WalletCard(document: card, isFront: isForward ? card == focused : index == cards.count - 1)
                            .frame(width: frame.width, height: WalletStack.cardHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(card == focused ? "focused card" : "key document \(card.libraryName ?? card.title)")
                    .offset(x: frame.minX, y: frame.minY)
                    .zIndex(card == focused ? 1 : 0)
                }

                topBar(for: focused, width: size.width)
                    .opacity(isForward ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { isForward = true }
        }
    }

    // MARK: Layout

    /// Where a card goes: in the stack before it comes forward; then the focused card at the top, the ones
    /// above it over the top edge, and the ones below it in a small stack at the bottom.
    private func place(_ card: SourceDocument, index: Int, size: CGSize, origin: CGPoint, top: CGFloat) -> CGRect {
        let rest = stackFrames[card.contentHash].map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ?? CGRect(x: 16, y: top, width: size.width - 32, height: WalletStack.cardHeight)
        guard isForward, let focused, let focusIndex = cards.firstIndex(of: focused) else { return rest }
        let width = size.width - 32
        if index == focusIndex { return CGRect(x: 16, y: top, width: width, height: WalletStack.cardHeight) }
        if index < focusIndex {
            // Above it: they leave over the top edge, the nearest last.
            return CGRect(x: 16, y: -origin.y - WalletStack.cardHeight - 40 - CGFloat(focusIndex - index) * 20, width: width, height: WalletStack.cardHeight)
        }
        // Below it: a small stack at the bottom, in the same order.
        let position = index - focusIndex - 1
        return CGRect(x: 16, y: restTop(size: size) + CGFloat(position) * Self.restPeek, width: width, height: WalletStack.cardHeight)
    }

    /// The top of the small stack at the bottom.
    private func restTop(size: CGSize) -> CGFloat {
        guard let focused, let focusIndex = cards.firstIndex(of: focused) else { return size.height }
        let below = cards.count - focusIndex - 1
        guard below > 0 else { return size.height }
        return size.height - Self.restHeight - CGFloat(below - 1) * Self.restPeek
    }

    // MARK: Parts

    private func topBar(for document: SourceDocument?, width: CGFloat) -> some View {
        HStack {
            Text(document.map { $0.kind == .other ? $0.title : $0.kind.displayName } ?? "")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Done") { close() }
                .fontWeight(.semibold)
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .frame(width: width, height: Self.barHeight)
    }

    private func details(for document: SourceDocument, top: CGFloat, bottom: CGFloat, width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    let fields = Self.fields(of: document)
                    if fields.isEmpty {
                        Text("No fields read from this document yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    ForEach(Array(fields.enumerated()), id: \.element.fact.persistentModelID) { index, field in
                        if index > 0 { Divider().padding(.leading, 14) }
                        fieldRow(field.fact, value: field.value)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dsSurface))
                Text("Tap a field to copy it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                Button {
                    let document = document
                    close { onOpen(document) }
                } label: {
                    Label("Open document", systemImage: "doc.text")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Color.dsTint)
                .accessibilityIdentifier("open document")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: max(bottom - top, 120))
        .offset(y: top)
    }

    /// The fields that have a value, in the document's order.
    private static func fields(of document: SourceDocument) -> [(fact: Fact, value: String)] {
        document.facts
            .filter { $0.status != .superseded }
            .sorted { ($0.key.sortOrder, $0.position) < ($1.key.sortOrder, $1.position) }
            .compactMap { fact in VaultReader.cardValue(fact).map { (fact, VaultReader.display($0, for: fact.key)) } }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isCopied ? Color.dsTintSoft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCopied ? "\(fact.displayLabel) copied" : "\(fact.displayLabel), \(value)")
        .accessibilityHint("Copies the value.")
    }

    // MARK: Actions

    /// Tapping the focused card puts the cards back; tapping another brings that one forward.
    private func select(_ card: SourceDocument) {
        guard isForward else { return }
        if card == focused {
            close()
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                focused = card
                copied = nil
            }
        }
    }

    private func close(then action: (() -> Void)? = nil) {
        guard isForward else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            isForward = false
        } completion: {
            focused = nil
            action?()
        }
    }
}
