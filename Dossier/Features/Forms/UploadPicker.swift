import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What a site's upload field opens in Dossier's browser: your documents, the ones that fit the field first,
/// then the photo library and Files for anything else. Documents go to the site under their library names.
struct UploadPicker: View {
    let request: UploadRequest
    let onFinish: ([URL]?) -> Void

    @Query private var documents: [SourceDocument]
    @State private var selected: [String] = []
    @State private var searchText = ""
    @State private var isImporting = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var isPreparing = false
    @State private var failed = false

    private var usable: [SourceDocument] {
        documents.filter { !$0.isGone && $0.isReady && $0.bookmark != nil && $0.kind != .addedByYou }
    }

    private var ranked: (suggested: [SourceDocument], others: [SourceDocument]) {
        let byID = Dictionary(usable.map { ($0.contentHash, $0) }, uniquingKeysWith: { first, _ in first })
        let result = UploadMatching.rank(usable.map(\.uploadCandidate), label: request.label, accept: request.accept)
        let matching = { (candidate: UploadMatching.Candidate) in
            searchText.isEmpty || candidate.text.localizedStandardContains(searchText)
        }
        return (
            result.suggested.filter(matching).compactMap { byID[$0.id] },
            result.others.filter(matching).compactMap { byID[$0.id] }.sorted { $0.uploadName.localizedStandardCompare($1.uploadName) == .orderedAscending }
        )
    }

    private var takesPhotos: Bool {
        UploadMatching.accepts(UploadMatching.acceptedTypes(request.accept), fileExtension: "jpg")
    }

    var body: some View {
        NavigationStack {
            let lists = ranked
            List {
                if !request.label.isEmpty {
                    Section {
                        Label(request.label, systemImage: "arrow.up.doc")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } header: {
                        Text("The site asks for")
                    }
                }
                if !lists.suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(lists.suggested) { row($0) }
                    }
                }
                Section(lists.suggested.isEmpty ? "Your documents" : "Other documents") {
                    if lists.others.isEmpty && lists.suggested.isEmpty {
                        Text(usable.isEmpty ? "No documents in Dossier yet." : searchText.isEmpty ? "None of your documents is a type this site takes." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lists.others) { row($0) }
                }
                Section {
                    if takesPhotos {
                        PhotosPicker(selection: $photos, maxSelectionCount: request.allowsMultiple ? 10 : 1, matching: .images) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                    }
                    Button("Other File…", systemImage: "folder") { isImporting = true }
                } footer: {
                    if failed { Text("Couldn’t open that file. If it’s in iCloud, check it has downloaded.").foregroundStyle(.red) }
                }
            }
            .searchable(text: $searchText, prompt: "Search your documents")
            .navigationTitle("Choose a Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish(nil) } }
                if request.allowsMultiple {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "Attach" : "Attach \(selected.count)") { attachSelected() }
                            .disabled(selected.isEmpty || isPreparing)
                    }
                }
            }
            .overlay {
                if isPreparing { ProgressView().controlSize(.large) }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: UploadMatching.contentTypes(request.accept), allowsMultipleSelection: request.allowsMultiple) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                Task { await attachFiles(urls) }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                Task { await attachPhotos(items) }
            }
        }
    }

    private func row(_ document: SourceDocument) -> some View {
        let isSelected = selected.contains(document.contentHash)
        return Button {
            if request.allowsMultiple {
                if isSelected { selected.removeAll { $0 == document.contentHash } } else { selected.append(document.contentHash) }
            } else {
                selected = [document.contentHash]
                attachSelected()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: FileAccess.isPDF(URL(filePath: document.fileName)) ? "doc.text" : "photo")
                    .font(.title3)
                    .foregroundStyle(Color.dsTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.uploadName).foregroundStyle(.primary).lineLimit(2)
                    Text(document.placement.map { [$0.category, $0.folder].joined(separator: " › ") } ?? document.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if request.allowsMultiple {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.dsTint : Color.secondary)
                }
            }
        }
        .disabled(isPreparing)
    }

    // MARK: Attaching

    private func attachSelected() {
        let chosen = selected.compactMap { id in usable.first { $0.contentHash == id } }
        let files = chosen.compactMap { document in document.bookmark.map { (bookmark: $0, name: document.uploadName) } }
        isPreparing = true
        Task {
            let urls = await Self.copies(of: files)
            isPreparing = false
            finish(urls, expected: files.count)
        }
    }

    private func attachFiles(_ picked: [URL]) async {
        isPreparing = true
        let urls = await Self.copies(ofPicked: picked)
        isPreparing = false
        finish(urls, expected: picked.count)
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        isPreparing = true
        var urls: [URL] = []
        for (number, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            if let url = try? UploadFiles.write(data, name: items.count == 1 ? "Photo.\(ext)" : "Photo \(number + 1).\(ext)") { urls.append(url) }
        }
        isPreparing = false
        photos = []
        finish(urls, expected: items.count)
    }

    private func finish(_ urls: [URL], expected: Int) {
        if urls.isEmpty, expected > 0 {
            failed = true
        } else {
            onFinish(urls)
        }
    }

    @concurrent
    private static func copies(of files: [(bookmark: Data, name: String)]) async -> [URL] {
        files.compactMap { file in
            guard let url = FileAccess.resolve(file.bookmark)?.url, let data = try? FileAccess.read(url) else { return nil }
            return try? UploadFiles.write(data, name: file.name)
        }
    }

    @concurrent
    private static func copies(ofPicked picked: [URL]) async -> [URL] {
        picked.compactMap { url in
            guard let data = try? FileAccess.read(url) else { return nil }
            return try? UploadFiles.write(data, name: url.lastPathComponent)
        }
    }
}

extension SourceDocument {
    /// The name a site sees: the library name when it has one, otherwise the file's own name.
    var uploadName: String {
        let ext = (fileName as NSString).pathExtension
        guard let name = placement?.name, !name.isEmpty else { return fileName }
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    var uploadCandidate: UploadMatching.Candidate {
        UploadMatching.Candidate(
            id: contentHash,
            kind: kind,
            text: [title, placement?.name, placement?.folder, placement?.category].compactMap { $0 }.joined(separator: " "),
            fileExtension: (fileName as NSString).pathExtension
        )
    }
}
