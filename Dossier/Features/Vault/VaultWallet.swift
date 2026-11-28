import SwiftData
import SwiftUI

// MARK: Category colors

/// Each category has its own color and symbol, so you can tell the shelves apart at a glance. Settings ›
/// Categories uses the same style. Ended documents still use the muted gray tile.
struct CategoryStyle {
    let tint: Color
    let soft: Color
    let symbol: String

    /// The 14 default categories. Old names (Housing, Tax and money) keep their colors until documents move.
    static func of(_ category: String) -> CategoryStyle {
        switch category {
        case "Identity": style(0x4B45C6, 0x8E8BFF, 0xE9E9F8, 0x29284D, "person.text.rectangle")
        case "Immigration": style(0x0B6F7A, 0x5AC8D8, 0xDDF1F2, 0x173A3E, "globe")
        case "Health": style(0xB0234F, 0xFF7EA3, 0xFBE4EB, 0x45202D, "heart.text.square")
        case "Insurance": style(0x6A4FB0, 0xB9A2FF, 0xECE6F8, 0x2F2650, "umbrella")
        case "Money", "Tax and money": style(0x1F5FB8, 0x7FB2FF, 0xE1ECFA, 0x1D2F4A, "banknote")
        case "Taxes": style(0x5B6B12, 0xC3D66B, 0xEEF2D9, 0x2E3414, "percent")
        case "Home", "Housing": style(0x2F6B3A, 0x7BD88F, 0xE2F1E4, 0x1C3A22, "house")
        case "Vehicles": style(0x4A5A6A, 0xA9B8C8, 0xE5E9EE, 0x2A3038, "car")
        case "Work": style(0x8A5A00, 0xF0C060, 0xF6EBD6, 0x3D3018, "briefcase")
        case "Education": style(0x9B3FA0, 0xE59BEA, 0xF5E3F5, 0x40214A, "graduationcap")
        case "Legal": style(0x6B4E3D, 0xD2B29C, 0xF0E8E2, 0x3A2C23, "building.columns")
        case "Purchases": style(0xA03A5F, 0xF59BBE, 0xF8E4EC, 0x442330, "bag")
        case "Travel": style(0x0A7EA4, 0x6CCBF0, 0xDCEFF7, 0x15384A, "airplane")
        case "Other": style(0x6E6E73, 0xAEAEB2, 0xEDEDF0, 0x2C2C2E, "tray")
        default: custom(category)
        }
    }

    /// A category you added gets one of the palette's colors, picked from its name so it stays the same.
    private static func custom(_ category: String) -> CategoryStyle {
        let palette = ["Identity", "Immigration", "Health", "Insurance", "Money", "Taxes", "Home", "Vehicles", "Work", "Education", "Legal", "Purchases", "Travel"]
        let index = category.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        let base = of(palette[index])
        return CategoryStyle(tint: base.tint, soft: base.soft, symbol: "folder")
    }

    private static func style(_ tint: UInt32, _ tintDark: UInt32, _ soft: UInt32, _ softDark: UInt32, _ symbol: String) -> CategoryStyle {
        CategoryStyle(tint: Color(light: tint, dark: tintDark), soft: Color(light: soft, dark: softDark), symbol: symbol)
    }
}

// MARK: Key documents

/// Which documents are Key documents (the card stack at the top of the Vault) and in what order. IDs in
/// use are added on their own; you can pin other documents, take an ID out, and reorder the stack.
/// Payment, loyalty and insurance cards are never added on their own: Dossier holds documents, not cards
/// for Apple Wallet. Stored as JSON in UserDefaults under `storageKey`, so a view that reads it with
/// `@AppStorage(KeyDocuments.storageKey)` updates when it changes.
nonisolated struct KeyDocuments: Codable, Equatable, Sendable {
    /// Content hashes of documents you added yourself.
    var pinned: [String] = []
    /// Content hashes of IDs you took out of the stack.
    var hidden: [String] = []
    /// Content hashes in stack order, top of the screen first. The last card is the one drawn whole.
    /// Key documents not listed here go after these, so a new ID shows in front.
    var order: [String] = []

    static let storageKey = "keyDocuments"

    /// Kinds that become Key documents on their own while they're in use. Back to front.
    static let automaticKinds: [DocumentKind] = [.visa, .employmentAuthorization, .greenCard, .stateID, .driversLicense, .passport]

    init() {}

    init(json: String) {
        self = (try? JSONDecoder().decode(KeyDocuments.self, from: Data(json.utf8))) ?? KeyDocuments()
    }

    var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The saved list.
    static var current: KeyDocuments {
        KeyDocuments(json: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// Changes the saved list.
    static func update(_ change: (inout KeyDocuments) -> Void) {
        var list = current
        change(&list)
        UserDefaults.standard.set(list.json, forKey: storageKey)
    }

    /// Whether a document is a Key document: pinned, or an ID in use that you didn't take out.
    func contains(hash: String, kind: DocumentKind, isInUse: Bool) -> Bool {
        if pinned.contains(hash) { return true }
        return Self.automaticKinds.contains(kind) && isInUse && !hidden.contains(hash)
    }

    /// Adds a document to the stack, in front.
    mutating func add(_ hash: String) {
        hidden.removeAll { $0 == hash }
        if !pinned.contains(hash) { pinned.append(hash) }
        order.removeAll { $0 == hash }
        order.append(hash)
    }

    /// Takes a document out of the stack. An ID stays out until you add it again.
    mutating func remove(_ hash: String, kind: DocumentKind) {
        pinned.removeAll { $0 == hash }
        order.removeAll { $0 == hash }
        if Self.automaticKinds.contains(kind), !hidden.contains(hash) { hidden.append(hash) }
    }

    /// Saves the stack's order as shown, top of the screen first.
    mutating func reorder(_ hashes: [String]) {
        order = hashes
    }

    /// Key documents, top of the screen first: in your order, then the rest by kind and person.
    func sorted<Item>(_ items: [Item], hash: (Item) -> String, kind: (Item) -> DocumentKind, person: (Item) -> String) -> [Item] {
        items.sorted { a, b in
            let x = order.firstIndex(of: hash(a)) ?? Int.max, y = order.firstIndex(of: hash(b)) ?? Int.max
            if x != y { return x < y }
            let p = Self.automaticKinds.firstIndex(of: kind(a)) ?? -1, q = Self.automaticKinds.firstIndex(of: kind(b)) ?? -1
            if p != q { return p < q }
            return person(a).localizedStandardCompare(person(b)) == .orderedDescending
        }
    }
}

// MARK: Wallet

/// Key documents as a stack of cards at the top of the Vault. Tapping a card brings it forward.
/// IDs that expired or were renewed leave the stack and stay on the shelves.
struct WalletStack: View {
    /// Back to front: the last card is drawn whole.
    let documents: [SourceDocument]
    /// Called when you tap a card.
    var onSelect: (SourceDocument) -> Void = { _ in }
    /// True while the cards are drawn forward on top of the Vault: the stack keeps its place, empty.
    var isLifted = false
    /// Where each card is on screen, by content hash, so the cards can come forward from there.
    var onFrame: (String, CGRect) -> Void = { _, _ in }

    static let cardHeight: CGFloat = 196
    static let peek: CGFloat = 54

    /// The Key documents among these, top of the screen first.
    static func cards(_ documents: [SourceDocument], keys: KeyDocuments, status: (SourceDocument) -> DocumentLifecycle.Status) -> [SourceDocument] {
        let chosen = documents.filter {
            $0.hasBeenRead && keys.contains(hash: $0.contentHash, kind: $0.kind, isInUse: !status($0).isEnded)
        }
        return keys.sorted(chosen, hash: { $0.contentHash }, kind: { $0.kind }, person: { $0.libraryPerson ?? "" })
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(documents.enumerated()), id: \.element.persistentModelID) { index, document in
                Button { onSelect(document) } label: {
                    WalletCard(document: document, isFront: index == documents.count - 1)
                        .frame(height: Self.cardHeight)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("card \(document.libraryName ?? document.title)")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame(document.contentHash, $0) }
                .contextMenu {
                    Button("Remove from Key Documents", systemImage: "rectangle.stack.badge.minus") {
                        KeyDocuments.update { $0.remove(document.contentHash, kind: document.kind) }
                    }
                }
                .offset(y: CGFloat(index) * Self.peek)
            }
        }
        .opacity(isLifted ? 0 : 1)
        .frame(height: Self.cardHeight + CGFloat(max(documents.count - 1, 0)) * Self.peek, alignment: .top)
        .padding(.vertical, 4)
    }
}

/// One Key document as a card: its type and whose it is, the full number, the name and the expiry date.
/// Collapsed cards show the top row only; the front card adds a picture of the document.
struct WalletCard: View {
    let document: SourceDocument
    let isFront: Bool

    private var color: Color {
        switch document.kind {
        case .passport: Color(light: 0x1E2A55, dark: 0x2A3A70)
        case .greenCard: Color(light: 0x0B6F7A, dark: 0x0E7C86)
        default: Color(light: 0x4B45C6, dark: 0x5E5CE6)
        }
    }

    private var isExpiring: Bool { document.badge == .expiring }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(document.walletTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isFront, isExpiring, let expiry = document.expiryDate {
                    Label("Expires \(SimpleDate(utc: expiry).display)", systemImage: "clock")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(light: 0xB25000, dark: 0xB25000))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white))
                } else if !isFront {
                    if isExpiring {
                        Image(systemName: "clock.fill")
                            .font(.footnote)
                            .foregroundStyle(Color(light: 0xFFB340, dark: 0xFFB340))
                            .accessibilityLabel("Expiring")
                    }
                    if let number = document.walletNumber {
                        Text(number)
                            .font(.system(.subheadline, design: .monospaced).weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            if isFront {
                Spacer(minLength: 8)
                HStack(alignment: .center, spacing: 14) {
                    WalletThumbnail(document: document)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        if let number = document.walletNumber {
                            GridRow {
                                field("Number", number, font: .system(.title3, design: .monospaced).weight(.semibold))
                                    .gridCellColumns(2)
                            }
                        }
                        GridRow {
                            field("Name", document.walletName ?? "—", font: .subheadline.weight(.medium))
                            field("Expires", document.expiryDate.map { SimpleDate(utc: $0).display } ?? "—", font: .subheadline.weight(.medium))
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.gradient))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func field(_ label: String, _ value: String, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).opacity(0.8)
            Text(value).font(font).lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

extension SourceDocument {
    /// Read, or being read again with what was read before: a card stays in the stack meanwhile, so the
    /// Vault doesn't jump while documents are read again.
    var hasBeenRead: Bool { isReady || (!facts.isEmpty && state != .failed && state != .awaitingDecision) }

    /// "Passport · Li": the card's type and whose it is. A document of no set kind goes by its own title,
    /// not "Document".
    var walletTitle: String { WalletText.title(kind: kind == .other ? title : kind.displayName, person: libraryPerson) }

    /// The document number, or the A-Number, in full. The Vault's Face ID unlock opens every number.
    var walletNumber: String? {
        guard let fact = fact(.documentNumber) ?? fact(.alienNumber) else { return nil }
        return VaultReader.cardValue(fact)
    }

    /// The holder's name as printed: given names, then surname.
    var walletName: String? {
        WalletText.name(given: fact(.givenNames).flatMap(VaultReader.cardValue), surname: fact(.surname).flatMap(VaultReader.cardValue))
    }
}

/// The text on a wallet card, kept apart from the views so tests can check it.
nonisolated enum WalletText {
    static func title(kind: String, person: String?) -> String {
        guard let person = person?.trimmingCharacters(in: .whitespaces), !person.isEmpty else { return kind }
        return "\(kind) · \(person)"
    }

    static func name(given: String?, surname: String?) -> String? {
        let parts = [given, surname].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: Shelves

/// One category as a shelf: its name, See all, and its folders as tiles that scroll sideways.
struct CategoryShelf: View {
    let section: LibraryGroups.Section<SourceDocument>
    let person: String?
    let statuses: [String: DocumentLifecycle.Status]
    var onReread: (SourceDocument) -> Void = { _ in }
    var onRemove: (SourceDocument) -> Void = { _ in }
    /// Opens the Move sheet for these documents: from Move to… (no category yet), or a drop on this shelf.
    var onMove: (_ documents: [SourceDocument], _ category: String?) -> Void = { _, _ in }
    /// Content hashes dropped on this shelf, to move here.
    var onDrop: (_ hashes: [String], _ category: String) -> Void = { _, _ in }

    /// True while a dragged tile is over this shelf.
    @State private var isTargeted = false

    private var style: CategoryStyle { .of(section.category) }

    /// What a dragged tile carries: its documents' content hashes, one per line.
    static func dragPayload(_ documents: [SourceDocument]) -> String {
        documents.map(\.contentHash).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.category)
                    .font(.title3.bold())
                    .foregroundStyle(isTargeted ? style.tint : .primary)
                if section.isShared {
                    Text("shared").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if isTargeted {
                    Text("Drop to move here").font(.subheadline.weight(.semibold)).foregroundStyle(style.tint)
                } else {
                    NavigationLink(value: VaultRoute.category(LibraryCategoryRoute(person: person, category: section.category, isShared: section.isShared))) {
                        Text("See all").font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsTint)
                    .accessibilityIdentifier("category \(section.category)")
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(section.folders) { folder in
                        tile(folder)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 6)
        // Touch and hold a tile, then drag it onto another shelf: the shelf lights up, and the drop opens Move.
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(style.soft)
                .strokeBorder(style.tint, lineWidth: 2)
                .padding(.horizontal, 8)
                .opacity(isTargeted ? 1 : 0)
        }
        .dropDestination(for: String.self) { items, _ in
            let hashes = items.flatMap { $0.split(separator: "\n").map(String.init) }
            guard !hashes.isEmpty else { return false }
            onDrop(hashes, section.category)
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.snappy, value: isTargeted)
    }

    @ViewBuilder private func tile(_ folder: LibraryGroups.Folder<SourceDocument>) -> some View {
        if folder.items.count == 1, let document = folder.items.first {
            let status = statuses[document.contentHash] ?? document.lifecycleStatus
            NavigationLink(value: VaultRoute.document(document.persistentModelID)) {
                ShelfTile(symbol: document.kind.symbol, badge: document.badge(status), title: folder.name, subtitle: shortSubtitle(document, status: status), style: style)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("document \(document.libraryName ?? document.title)")
            .draggable(Self.dragPayload([document])) {
                ShelfTile(symbol: document.kind.symbol, badge: document.badge(status), title: folder.name, subtitle: shortSubtitle(document, status: status), style: style)
            }
            .contextMenu {
                Button("Move to…", systemImage: "folder") { onMove([document], nil) }
                Button("Add to Key Documents", systemImage: "rectangle.stack.badge.plus") {
                    KeyDocuments.update { $0.add(document.contentHash) }
                }
                Button("Read again", systemImage: "arrow.clockwise") { onReread(document) }
                Button("Remove from Vault", systemImage: "trash", role: .destructive) { onRemove(document) }
            }
        } else {
            NavigationLink(value: VaultRoute.folder(LibraryFolderRoute(person: person, category: section.category, folder: folder.name, isShared: section.isShared))) {
                ShelfTile(symbol: folder.items.first?.kind.symbol ?? "folder", badge: folderBadge(folder.items), title: folder.name, subtitle: folderSubtitle(folder.items), style: style, count: folder.items.count)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("folder \(folder.name)")
            .draggable(Self.dragPayload(folder.items)) {
                ShelfTile(symbol: folder.items.first?.kind.symbol ?? "folder", badge: folderBadge(folder.items), title: folder.name, subtitle: folderSubtitle(folder.items), style: style, count: folder.items.count)
            }
            .contextMenu {
                Button("Move to…", systemImage: "folder") { onMove(folder.items, nil) }
            }
        }
    }

    private func status(_ document: SourceDocument) -> DocumentLifecycle.Status {
        statuses[document.contentHash] ?? document.lifecycleStatus
    }

    private func shortSubtitle(_ document: SourceDocument, status: DocumentLifecycle.Status) -> String {
        switch status {
        case .renewed: return "Renewed"
        case .expired: return "Expired"
        default: break
        }
        if let expiry = document.expiryDate { return "Until \(SimpleDate(utc: expiry).display)" }
        let facts = document.libraryFacts
        if let years = LibraryGroups.years([facts.from, facts.until, facts.date].compactMap { $0 }) { return years }
        return document.kind.displayName
    }

    private func folderSubtitle(_ documents: [SourceDocument]) -> String {
        let dates = documents.flatMap { [$0.libraryFacts.from, $0.libraryFacts.until, $0.libraryFacts.date].compactMap { $0 } }
        return LibraryGroups.years(dates) ?? "\(documents.count) documents"
    }

    /// The badge of the document that most needs you; ended ones count only when all have ended.
    private func folderBadge(_ documents: [SourceDocument]) -> TileBadge {
        let badges = documents.map { $0.badge(status($0)) }
        let inUse = badges.filter { !$0.isEnded }
        if inUse.isEmpty { return documents.first.map { status($0).isRenewed } == true ? .renewed : .expired }
        return inUse.contains(.review) ? .review : inUse.contains(.expiring) ? .expiring : inUse.contains(.reading) ? .reading : .verified
    }
}

/// A folder or document on a shelf.
struct ShelfTile: View {
    let symbol: String
    let badge: TileBadge
    let title: String
    let subtitle: String
    let style: CategoryStyle
    var count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                BadgedTile(symbol: symbol, badge: badge, size: 34, tint: style.tint, soft: style.soft)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(style.soft))
                }
            }
            Spacer(minLength: 8)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(badge == .expiring ? Color.dsWarning : .secondary)
        }
        .padding(12)
        .frame(width: 132, height: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dsSurface))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: See all

/// One category's shelf, as the Vault shows it.
struct LibraryCategoryRoute: Hashable {
    /// The person the Vault was showing; nil for everyone.
    var person: String?
    var category: String
    /// The category's Household documents shown with one person's.
    var isShared: Bool
}

/// Every document in one category, a section per folder. Reads them itself, so it stays current while it's open.
struct LibraryCategoryView: View {
    let route: LibraryCategoryRoute

    @Query private var documents: [SourceDocument]

    var body: some View {
        let statuses = documents.lifecycle()
        let placed = documents.compactMap { document in document.placement.map { (item: document, placement: $0) } }
        let section = LibraryGroups.sections(placed, person: route.person, status: { statuses[$0.contentHash] ?? .current })
            .first { $0.category == route.category && $0.isShared == route.isShared }
        List {
            ForEach(section?.folders ?? []) { folder in
                Section(folder.name) {
                    ForEach(folder.items) { document in
                        NavigationLink(value: VaultRoute.document(document.persistentModelID)) {
                            DocumentRow(document: document, status: statuses[document.contentHash])
                        }
                        .accessibilityIdentifier("document \(document.libraryName ?? document.title)")
                    }
                }
            }
        }
        .overlay {
            if section == nil { ContentUnavailableView("No documents here now", systemImage: "folder") }
        }
        .navigationTitle(route.category)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let name = CategoryList.current.resolve(route.category) {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        CategoryDetailView(name: name)
                    } label: {
                        Label("Edit Category", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("edit category")
                }
            }
        }
    }
}
