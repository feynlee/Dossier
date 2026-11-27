import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Editing a document's file: delete, reorder and rotate pages, and insert pages from a scan. A PDF is saved
/// back to its file. A photo is turned into a PDF first, saved to iCloud Drive (the photo isn't changed),
/// and the document then uses the PDF. Either way the document is read again.
struct PageEditor: View {
    let document: SourceDocument

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var draft = PageDraft()
    @State private var selection: Set<UUID> = []
    @State private var dropTarget: UUID?
    @State private var isScanning = false
    @State private var isWorking = false
    @State private var savingAsPDF: Data?
    @State private var confirmDiscard = false
    @State private var errorMessage: String?

    private var isPDF: Bool { draft.isPDF }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let loadError = draft.loadError {
                    ContentUnavailableView("Can’t open the file", systemImage: "doc.questionmark", description: Text(loadError))
                        .padding(.top, 60)
                } else if draft.pages.isEmpty, draft.isLoaded {
                    ContentUnavailableView {
                        Label("No pages", systemImage: "doc")
                    } description: {
                        Text("A document needs at least one page. Scan pages to add them.")
                    } actions: {
                        Button("Scan Pages", systemImage: "doc.viewfinder") { isScanning = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(page: page, number: index + 1, isSelected: selection.contains(page.id), isDropTarget: dropTarget == page.id)
                                .onTapGesture { toggle(page.id) }
                                .draggable(page.id.uuidString) {
                                    PageThumbnail(image: page.thumbnail).frame(width: 90)
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let moved = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                                    withAnimation(.snappy) { draft.move(moved, before: page.id) }
                                    return true
                                } isTargeted: { targeted in
                                    dropTarget = targeted ? page.id : (dropTarget == page.id ? nil : dropTarget)
                                }
                        }
                    }
                    .padding(20)
                    Text(isPDF
                        ? "Tap pages to select them. Touch and hold a page to drag it to a new place. Changes are saved to \(document.fileName) in iCloud Drive."
                        : "Tap pages to select them. Touch and hold a page to drag it to a new place. \(document.fileName) is a photo, so Dossier saves your pages as a new PDF and leaves the photo as it is.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay { if !draft.isLoaded { ProgressView() } }
            .navigationTitle("Edit Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await draft.load(document) }
            .fullScreenCover(isPresented: $isScanning) {
                DocumentScanner(onPages: insert, finishTitle: "Insert")
            }
            .sheet(isPresented: Binding(get: { savingAsPDF != nil }, set: { if !$0 { savingAsPDF = nil } })) {
                if let pdf = savingAsPDF {
                    SavePDFSheet(
                        title: "Save as PDF",
                        previews: draft.pages.compactMap { $0.thumbnail?.pngData() },
                        suggestedName: (document.fileName as NSString).deletingPathExtension,
                        makePDF: { pdf }
                    ) { file, folder in
                        savingAsPDF = nil
                        do {
                            try importer.attach(file, within: folder, to: document, context: modelContext, preferPrivateCloud: usePrivateCloud)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Couldn’t save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(draft.hasChanges || isWorking)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { if draft.hasChanges { confirmDiscard = true } else { dismiss() } }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isWorking {
                ProgressView()
            } else {
                Button("Save") { save() }
                    .disabled(!(draft.hasChanges || !isPDF) || draft.pages.isEmpty)
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Insert from Scan", systemImage: "doc.viewfinder") { isScanning = true }
                .disabled(!draft.isLoaded || draft.loadError != nil)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Text(statusText).font(.footnote).foregroundStyle(.secondary).fixedSize()
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Rotate", systemImage: "rotate.right") {
                withAnimation(.snappy) { draft.rotate(selection) }
            }
            .disabled(selection.isEmpty)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation(.snappy) { draft.delete(selection) }
                selection = []
            }
            .disabled(selection.isEmpty)
        }
    }

    private var statusText: String {
        let count = draft.pages.count
        let pages = count == 1 ? "1 page" : "\(count) pages"
        return selection.isEmpty ? pages : "\(selection.count) of \(count) selected"
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Scanned pages go after the last selected page, or at the end. They're selected afterwards, so you can
    /// see where they went.
    private func insert(_ scanned: [ScannedPage]) {
        let after = draft.pages.lastIndex { selection.contains($0.id) }
        let inserted = draft.insert(scanned, after: after)
        selection = Set(inserted)
    }

    private func save() {
        guard let pdf = draft.pdfData() else {
            errorMessage = "The pages couldn’t be put together."
            return
        }
        guard isPDF, let url = document.bookmark.flatMap(FileAccess.resolve)?.url else {
            savingAsPDF = pdf
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try FileAccess.write(pdf, to: url)
            importer.reread(document, context: modelContext, preferPrivateCloud: usePrivateCloud)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The pages being edited, as PDF pages, with what changed.
@Observable
final class PageDraft {
    struct Page: Identifiable {
        let id = UUID()
        var page: PDFPage
        var thumbnail: UIImage?
    }

    private(set) var pages: [Page] = []
    private(set) var isLoaded = false
    private(set) var isPDF = true
    private(set) var loadError: String?
    private(set) var hasChanges = false

    func load(_ document: SourceDocument) async {
        defer { isLoaded = true }
        guard let url = document.bookmark.flatMap(FileAccess.resolve)?.url else {
            loadError = "The file can’t be found. It may have been moved or deleted."
            return
        }
        isPDF = FileAccess.isPDF(url)
        let isPDF = isPDF
        let pdf: Data? = await Task.detached {
            guard let data = try? FileAccess.read(url) else { return nil }
            return isPDF ? data : ScanPDF.make(photo: data)
        }.value
        guard let pdf, let source = PDFDocument(data: pdf), source.pageCount > 0 else {
            loadError = "The file can’t be opened."
            return
        }
        pages = (0..<source.pageCount).compactMap { source.page(at: $0) }.map { Self.page($0) }
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: from)
        let to = pages.firstIndex { $0.id == target } ?? pages.count
        // Dragging down puts the page after the target; dragging up, before it.
        pages.insert(page, at: from <= to ? min(to + 1, pages.count) : to)
        hasChanges = true
    }

    func rotate(_ ids: Set<UUID>) {
        for index in pages.indices where ids.contains(pages[index].id) {
            pages[index].page.rotation = (pages[index].page.rotation + 90) % 360
            pages[index].thumbnail = Self.thumbnail(pages[index].page)
        }
        hasChanges = true
    }

    func delete(_ ids: Set<UUID>) {
        pages.removeAll { ids.contains($0.id) }
        hasChanges = true
    }

    /// Returns the new pages' ids.
    func insert(_ scanned: [ScannedPage], after index: Int?) -> [UUID] {
        guard let data = ScanPDF.make(scanned), let source = PDFDocument(data: data) else { return [] }
        let new = (0..<source.pageCount).compactMap { source.page(at: $0) }.map { Self.page($0) }
        pages.insert(contentsOf: new, at: index.map { $0 + 1 } ?? pages.count)
        hasChanges = true
        return new.map(\.id)
    }

    func pdfData() -> Data? {
        let output = PDFDocument()
        for (index, page) in pages.enumerated() {
            guard let copy = page.page.copy() as? PDFPage else { return nil }
            output.insert(copy, at: index)
        }
        return output.pageCount > 0 ? output.dataRepresentation() : nil
    }

    private static func page(_ page: PDFPage) -> Page {
        let copy = (page.copy() as? PDFPage) ?? page
        return Page(page: copy, thumbnail: thumbnail(copy))
    }

    private static func thumbnail(_ page: PDFPage) -> UIImage {
        page.thumbnail(of: CGSize(width: 360, height: 480), for: .cropBox)
    }
}

private struct PageCell: View {
    let page: PageDraft.Page
    let number: Int
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        VStack(spacing: 8) {
            PageThumbnail(image: page.thumbnail)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.dsTint : .clear, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white, isSelected ? Color.dsTintFill : .black.opacity(0.25))
                        .padding(8)
                        .shadow(radius: 1)
                }
                .overlay(alignment: .leading) {
                    if isDropTarget {
                        Capsule().fill(Color.dsTint).frame(width: 4).offset(x: -12)
                    }
                }
                .scaleEffect(isSelected ? 0.96 : 1)
            Text("\(number)")
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.dsTint : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

private struct PageThumbnail: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground)).aspectRatio(0.77, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
