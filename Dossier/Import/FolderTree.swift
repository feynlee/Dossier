import Foundation

/// Everything Dossier can read inside a folder you picked, as a tree, and which of those files you've ticked.
/// Only PDFs and photos are kept, and only folders that hold some, so the tree shows nothing you can't add.
nonisolated struct FolderTree: Sendable {
    struct Node: Identifiable, Sendable, Equatable {
        /// The path from the picked folder ("Immigration/EAD 2024/EAD_front.jpg"); "" for the picked folder.
        var id: String
        var name: String
        var url: URL
        var isFolder: Bool
        var isPDF = false
        var size: Int?
        var children: [Node] = []

        /// Every file at or below this node.
        var files: [Node] { isFolder ? children.flatMap(\.files) : [self] }
    }

    let root: Node

    /// Lists the folder and everything inside it, in its security scope. Hidden files are skipped; an iCloud
    /// file that isn't downloaded yet is listed under its real name.
    static func scan(_ folder: URL) -> FolderTree {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let name = folder.lastPathComponent
        return FolderTree(root: node(at: folder, id: "", name: name) ?? Node(id: "", name: name, url: folder, isFolder: true))
    }

    private static func node(at url: URL, id: String, name: String) -> Node? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        var children: [Node] = []
        for entry in entries {
            guard let name = visibleName(entry.lastPathComponent) else { continue }
            let entryURL = url.appending(path: name)
            let childID = id.isEmpty ? name : "\(id)/\(name)"
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if let folder = node(at: entryURL, id: childID, name: name) { children.append(folder) }
            } else if FileAccess.isReadable(entryURL) {
                children.append(Node(id: childID, name: name, url: entryURL, isFolder: false, isPDF: FileAccess.isPDF(entryURL), size: values?.fileSize))
            }
        }
        guard !children.isEmpty || id.isEmpty else { return nil }
        // Folders first, then files, each by name as Files sorts them.
        children.sort { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
        return Node(id: id, name: name, url: url, isFolder: true, children: children)
    }

    /// The name to show, or nil for a hidden file. ".Passport.pdf.icloud" is a file still in iCloud.
    static func visibleName(_ name: String) -> String? {
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            let real = String(name.dropFirst().dropLast(".icloud".count))
            return real.isEmpty ? nil : real
        }
        return name.hasPrefix(".") ? nil : name
    }

    // MARK: Filtering

    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case pdfs = "PDFs"
        case photos = "Photos"
        case notAdded = "New"

        var id: Self { self }
    }

    /// The tree with only matching files, and the folders that still hold some. A search matches file and
    /// folder names; a matching folder keeps everything inside it.
    func filtered(_ filter: Filter, search: String, added: Set<String>) -> Node {
        Self.filter(root, filter: filter, search: search.trimmingCharacters(in: .whitespaces), added: added) ?? Node(id: root.id, name: root.name, url: root.url, isFolder: true)
    }

    private static func filter(_ node: Node, filter: Filter, search: String, added: Set<String>) -> Node? {
        if !node.isFolder {
            let kindMatches = switch filter {
            case .all: true
            case .pdfs: node.isPDF
            case .photos: !node.isPDF
            case .notAdded: !added.contains(node.id)
            }
            return kindMatches && (search.isEmpty || node.name.localizedCaseInsensitiveContains(search)) ? node : nil
        }
        let folderMatches = !node.id.isEmpty && !search.isEmpty && node.name.localizedCaseInsensitiveContains(search)
        let children = node.children.compactMap { Self.filter($0, filter: filter, search: folderMatches ? "" : search, added: added) }
        guard !children.isEmpty || node.id.isEmpty else { return nil }
        var kept = node
        kept.children = children
        return kept
    }

    // MARK: Rows

    struct Row: Identifiable, Equatable {
        var node: Node
        var depth: Int
        var isExpanded: Bool
        var id: String { node.id }
    }

    /// The rows to show: the picked folder's contents, and the contents of each open folder below its row.
    static func rows(of node: Node, expanded: Set<String>, depth: Int = 0) -> [Row] {
        node.children.flatMap { child -> [Row] in
            let isOpen = child.isFolder && expanded.contains(child.id)
            let row = Row(node: child, depth: depth, isExpanded: isOpen)
            return isOpen ? [row] + rows(of: child, expanded: expanded, depth: depth + 1) : [row]
        }
    }
}

/// Which files you've ticked. A folder is ticked when all its files are, partly ticked when some are.
nonisolated struct FolderSelection: Equatable, Sendable {
    enum State: Equatable { case none, some, all, added }

    /// Ids of ticked files.
    var selected: Set<String> = []
    /// Ids of files already in Dossier. They can't be ticked again.
    var added: Set<String> = []

    func state(of node: FolderTree.Node) -> State {
        let files = node.files.filter { !added.contains($0.id) }
        if files.isEmpty { return node.files.isEmpty ? .none : .added }
        let ticked = files.filter { selected.contains($0.id) }.count
        return ticked == 0 ? .none : ticked == files.count ? .all : .some
    }

    /// Ticks a file or every file in a folder; unticks them if they were all ticked.
    mutating func toggle(_ node: FolderTree.Node) {
        let files = node.files.map(\.id).filter { !added.contains($0) }
        if state(of: node) == .all {
            selected.subtract(files)
        } else {
            selected.formUnion(files)
        }
    }

    /// The ticked files, in tree order.
    func files(in tree: FolderTree) -> [FolderTree.Node] {
        tree.root.files.filter { selected.contains($0.id) }
    }

    /// How many folders the ticked files come from.
    func folderCount(in tree: FolderTree) -> Int {
        Set(files(in: tree).map { ($0.id as NSString).deletingLastPathComponent }).count
    }
}
