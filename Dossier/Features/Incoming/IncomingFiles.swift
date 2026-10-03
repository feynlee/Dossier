import Observation
import PDFKit
import SwiftData
import SwiftUI

/// Files sent to Dossier from other apps: the share sheet, or Open In. Files are opened in place, so a file
/// that's already in iCloud Drive is added where it is. Anything else (a Mail attachment, a file On My
/// iPhone) arrives as a copy, which is saved to a folder in iCloud Drive you choose, then added; the copy
/// Dossier was given is deleted.
@Observable
final class IncomingFiles {
    private(set) var queue: [URL] = []
    /// "Added Passport.pdf from iCloud Drive › Documents", shown for a moment.
    var notice: String?

    var current: URL? { queue.first }

    func receive(_ url: URL) {
        guard url.isFileURL, !queue.contains(url) else { return }
        queue.append(url)
    }

    func finish(_ url: URL) {
        queue.removeAll { $0 == url }
        // Copies handed to Dossier land in its own container (Documents/Inbox); nothing else is deleted.
        if Self.isCopyInDossier(url) { try? FileManager.default.removeItem(at: url) }
    }

    static func isCopyInDossier(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(URL.homeDirectory.standardizedFileURL.path)
    }

    enum Route {
        /// Not a PDF or photo.
        case unsupported
        /// Already in iCloud Drive: add it where it is.
        case addInPlace
        /// Needs a home in iCloud Drive first.
        case chooseFolder
    }

    static func route(for url: URL) -> Route {
        guard FileAccess.isReadable(url) else { return .unsupported }
        return !isCopyInDossier(url) && ScanFolders.isInICloud(url) ? .addInPlace : .chooseFolder
    }

    /// A small picture of the file's first page.
    static func preview(of url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if FileAccess.isPDF(url) {
            return PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox).pngData()
        }
        return UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 240, height: 320))?.pngData()
    }
}

/// Handles files sent to Dossier once it's unlocked: adds them, or asks where to keep them in iCloud Drive.
struct IncomingFilesModifier: ViewModifier {
    let incoming: IncomingFiles
    let isLocked: Bool

    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var choosingFolder: URL?

    func body(content: Content) -> some View {
        content
            .onOpenURL { incoming.receive($0) }
            .onChange(of: incoming.current, initial: true) { handleNext() }
            .onChange(of: isLocked) { handleNext() }
            .sheet(item: Binding(get: { choosingFolder.map(IncomingURL.init) }, set: { if $0 == nil { done() } })) { item in
                let url = item.url
                SavePDFSheet(
                    title: "Add to Dossier",
                    previews: [IncomingFiles.preview(of: url)].compactMap { $0 },
                    suggestedName: url.deletingPathExtension().lastPathComponent,
                    fileExtension: url.pathExtension.isEmpty ? "pdf" : url.pathExtension.lowercased(),
                    footer: "Dossier keeps your documents in iCloud Drive. A copy of \(url.lastPathComponent) is saved to this folder, then read. The file you shared isn’t changed.",
                    makePDF: { try? FileAccess.read(url) }
                ) { file, folder in
                    if importer.add([file], within: folder, context: modelContext, preferPrivateCloud: usePrivateCloud) > 0 {
                        show("Added \(file.lastPathComponent) to \(FolderAccess.displayPath(for: folder))")
                    }
                    done()
                }
            }
            .overlay(alignment: .top) {
                if let notice = incoming.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .symbolRenderingMode(.multicolor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation { incoming.notice = nil }
                        }
                }
            }
    }

    private func handleNext() {
        guard !isLocked, choosingFolder == nil, let url = incoming.current else { return }
        switch IncomingFiles.route(for: url) {
        case .unsupported:
            show("\(url.lastPathComponent) isn’t a PDF or photo, so it wasn’t added.")
            incoming.finish(url)
        case .addInPlace:
            let added = importer.add([url], context: modelContext, preferPrivateCloud: usePrivateCloud)
            let location = FolderAccess.displayPath(for: url.deletingLastPathComponent())
            show(added > 0 ? "Added \(url.lastPathComponent) from \(location)" : "\(url.lastPathComponent) is already in Dossier")
            incoming.finish(url)
        case .chooseFolder:
            choosingFolder = url
        }
    }

    /// Clears the sheet first, so the next file in the queue is handled.
    private func done() {
        guard let url = choosingFolder else { return }
        choosingFolder = nil
        incoming.finish(url)
    }

    private func show(_ message: String) {
        withAnimation { incoming.notice = message }
    }
}

private struct IncomingURL: Identifiable {
    let url: URL
    var id: URL { url }
}
