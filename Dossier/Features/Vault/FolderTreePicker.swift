import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Choosing files from a folder and everything inside it. You pick the folder once in the Files picker, then
/// tick files, or whole folders, in a tree. Files already in Dossier are marked and can't be added twice.
struct FolderTreePicker: View {
    let folder: URL
    var onChangeFolder: () -> Void = {}
    var onAdded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @Query private var documents: [SourceDocument]
    @State private var tree: FolderTree?
    @State private var selection = FolderSelection()
    @State private var expanded: Set<String> = []
    @State private var filter = FolderTree.Filter.all
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.title3)
                            .foregroundStyle(Color.dsTint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.lastPathComponent).font(.headline)
                            Text(FolderAccess.displayPath(for: folder)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change", action: onChangeFolder)
                            .buttonStyle(.borderless)
                            .tint(Color.dsTint)
                    }
                    Picker("Show", selection: $filter) {
                        ForEach(FolderTree.Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }

                if let tree {
                    let rows = visibleRows(in: tree)
                    Section {
                        if rows.isEmpty {
                            Text(tree.root.children.isEmpty ? "No PDFs or photos in this folder." : "No matches.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(rows) { row in
                            FolderTreeRow(
                                row: row,
                                state: selection.state(of: row.node),
                                detail: detail(for: row.node),
                                onToggle: { selection.toggle(row.node) },
                                onExpand: { toggleExpanded(row.node) }
                            )
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking through \(folder.lastPathComponent)…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose files")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let tree {
                        let visible = tree.filtered(filter, search: searchText, added: selection.added)
                        Button(selection.state(of: visible) == .all ? "Deselect all" : "Select all") {
                            selection.toggle(visible)
                        }
                        .disabled(selection.state(of: visible) == .added || visible.children.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let tree {
                    SelectionBar(
                        count: selection.selected.count,
                        folders: selection.folderCount(in: tree),
                        alreadyAdded: selection.added.count,
                        onAdd: { add(from: tree) }
                    )
                }
            }
            .task(id: folder) { await load() }
        }
    }

    private var searchPrompt: String {
        guard let tree else { return "Search" }
        let count = tree.root.files.count
        return count == 1 ? "Search 1 file" : "Search \(count) files"
    }

    /// While searching, every folder with a match is open.
    private func visibleRows(in tree: FolderTree) -> [FolderTree.Row] {
        let visible = tree.filtered(filter, search: searchText, added: selection.added)
        let isFiltering = !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all
        let open = isFiltering ? Set(allFolders(in: visible)) : expanded
        return FolderTree.rows(of: visible, expanded: open)
    }

    private func allFolders(in node: FolderTree.Node) -> [String] {
        node.children.filter(\.isFolder).flatMap { [$0.id] + allFolders(in: $0) }
    }

    private func toggleExpanded(_ node: FolderTree.Node) {
        withAnimation(.snappy) {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        }
    }

    private func detail(for node: FolderTree.Node) -> String {
        if node.isFolder {
            let files = node.files.count
            let ticked = node.files.filter { selection.selected.contains($0.id) }.count
            if ticked > 0 { return "\(ticked) of \(files)" }
            return files == 1 ? "1 file" : "\(files) files"
        }
        if selection.added.contains(node.id) { return "In Dossier" }
        return node.size.map { Int64($0).formatted(.byteCount(style: .file)) } ?? ""
    }

    private func load() async {
        let folder = folder
        let scanned = await Task.detached(priority: .userInitiated) { FolderTree.scan(folder) }.value
        let existing = Set(documents.compactMap { $0.bookmark.flatMap(FileAccess.resolve)?.url.standardizedFileURL.path })
        selection = FolderSelection(added: Set(scanned.root.files.filter { existing.contains($0.url.standardizedFileURL.path) }.map(\.id)))
        // A small folder opens fully; a large one shows its top level.
        expanded = scanned.root.files.count <= 30 ? Set(allFolders(in: scanned.root)) : []
        tree = scanned
    }

    private func add(from tree: FolderTree) {
        let urls = selection.files(in: tree).map(\.url)
        let added = importer.add(urls, within: folder, context: modelContext, preferPrivateCloud: usePrivateCloud)
        dismiss()
        if added > 0 { onAdded() }
    }
}

private struct FolderTreeRow: View {
    let row: FolderTree.Row
    let state: FolderSelection.State
    let detail: String
    let onToggle: () -> Void
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: checkSymbol)
                    .font(.title3)
                    .foregroundStyle(state == .none ? Color.secondary : Color.dsTint)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(state == .added)
            .accessibilityLabel(checkLabel)

            Button(action: row.node.isFolder ? onExpand : onToggle) {
                HStack(spacing: 8) {
                    if row.node.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                            .frame(width: 12)
                    }
                    Image(systemName: row.node.isFolder ? "folder" : row.node.isPDF ? "doc.text" : "photo")
                        .foregroundStyle(Color.dsTint)
                        .frame(width: 22)
                    Text(row.node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.node.isFolder && state == .added)
            .accessibilityHint(row.node.isFolder ? (row.isExpanded ? "Closes the folder" : "Opens the folder") : "")
        }
        .padding(.leading, CGFloat(row.depth) * 22)
    }

    private var checkSymbol: String {
        switch state {
        case .all: "checkmark.circle.fill"
        case .some: "minus.circle.fill"
        case .none: "circle"
        case .added: "checkmark.seal"
        }
    }

    private var checkLabel: String {
        switch state {
        case .all: "Selected, \(row.node.name)"
        case .some: "Partly selected, \(row.node.name)"
        case .none: "Not selected, \(row.node.name)"
        case .added: "Already in Dossier, \(row.node.name)"
        }
    }
}

/// "7 files selected · from 3 folders", and the Add button.
private struct SelectionBar: View {
    let count: Int
    let folders: Int
    let alreadyAdded: Int
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 file selected" : "\(count) files selected").font(.subheadline.weight(.semibold))
                Text(caption).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button(count > 0 ? "Add \(count)" : "Add", action: onAdd)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.dsTintFill)
                .disabled(count == 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var caption: String {
        var parts: [String] = []
        if count > 0 { parts.append(folders == 1 ? "From 1 folder" : "From \(folders) folders") }
        if alreadyAdded > 0 { parts.append(alreadyAdded == 1 ? "1 already in Dossier" : "\(alreadyAdded) already in Dossier") }
        return parts.isEmpty ? "Tick files or whole folders" : parts.joined(separator: " · ")
    }
}

/// Choosing files in Dossier's own list, `FolderTreePicker`, starting in the folder you chose files from
/// last time. The Files picker opens only to choose a folder: the first time, or when you tap Change.
struct ChooseFromFolderModifier: ViewModifier {
    @Binding var isPresented: Bool
    /// Set to open the tree straight away, for a folder you dropped on the Vault.
    @Binding var folder: URL?
    var onAdded: () -> Void = {}

    @State private var isChoosingFolder = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                guard presented else { return }
                isPresented = false
                if let last = LastFolder.url { folder = last } else { isChoosingFolder = true }
            }
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    LastFolder.remember(url)
                    folder = url
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .sheet(item: Binding(get: { folder.map(PickedFolder.init) }, set: { if $0 == nil { folder = nil } })) { picked in
                FolderTreePicker(folder: picked.url, onChangeFolder: changeFolder, onAdded: onAdded)
            }
            .alert("Couldn’t open the folder", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// Closes the tree, then opens the Files picker to choose another folder once the sheet is gone.
    private func changeFolder() {
        folder = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            isChoosingFolder = true
        }
    }
}

/// The folder you last chose files from, kept as a bookmark so Dossier can open it again.
nonisolated enum LastFolder {
    private static let key = "lastChosenFolder"

    static var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: key), let resolved = FileAccess.resolve(data) else { return nil }
        guard FileAccess.exists(resolved.url) else {
            forget()
            return nil
        }
        if let refreshed = resolved.refreshed { UserDefaults.standard.set(refreshed, forKey: key) }
        return resolved.url
    }

    static func remember(_ folder: URL) {
        guard let data = try? FileAccess.bookmark(for: folder) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private struct PickedFolder: Identifiable {
    let url: URL
    var id: URL { url }
}

extension View {
    func chooseFromFolder(isPresented: Binding<Bool>, folder: Binding<URL?>, onAdded: @escaping () -> Void = {}) -> some View {
        modifier(ChooseFromFolderModifier(isPresented: isPresented, folder: folder, onAdded: onAdded))
    }
}

/// A file or folder dropped on the Vault from another app.
nonisolated enum DroppedItem: Sendable {
    /// A file opened where it is, to add in place.
    case file(URL)
    /// A folder opened where it is, to choose files from.
    case folder(URL)
    /// A copy Dossier was given, saved in its Inbox like files shared to it.
    case copy(URL)

    static func load(_ provider: NSItemProvider) async -> DroppedItem? {
        await withCheckedContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, isInPlace, _ in
                guard let url else { return continuation.resume(returning: nil) }
                if isInPlace {
                    let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return continuation.resume(returning: isFolder ? .folder(url) : .file(url))
                }
                // The copy is deleted when this returns, so keep one where shared files arrive.
                let inbox = URL.documentsDirectory.appending(path: "Inbox/\(UUID().uuidString)", directoryHint: .isDirectory)
                let copy = inbox.appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: .copy(copy))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
