import PDFKit
import SwiftUI
import UIKit

/// The original file, zoomable and pannable, with the selected fact outlined where it was read.
struct DocumentPreview: UIViewRepresentable {
    let pdf: PDFDocument
    /// 1-based page and the normalized (top-left origin) box of the selected fact.
    var highlight: (page: Int, rect: CGRect)?

    private static let highlightName = "dossier-highlight"

    final class Coordinator {
        /// The highlight last zoomed to, so re-renders don't undo your own zooming.
        var lastHighlight: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemGroupedBackground
        view.document = pdf
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== pdf { view.document = pdf }
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == Self.highlightName {
                page.removeAnnotation(annotation)
            }
        }
        guard let highlight, let page = pdf.page(at: highlight.page - 1) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let r = highlight.rect
        let box = CGRect(
            x: bounds.minX + r.minX * bounds.width,
            y: bounds.minY + (1 - r.maxY) * bounds.height,
            width: r.width * bounds.width,
            height: r.height * bounds.height
        ).insetBy(dx: -4, dy: -3)

        let annotation = PDFAnnotation(bounds: box, forType: .square, withProperties: nil)
        annotation.userName = Self.highlightName
        let tint = UIColor(Color.dsTint)
        annotation.color = tint
        annotation.interiorColor = tint.withAlphaComponent(0.15)
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)

        // Zoom in on a newly selected fact so the value is legible next to what was extracted.
        let key = "\(highlight.page)#\(r.debugDescription)"
        guard context.coordinator.lastHighlight != key else { return }
        context.coordinator.lastHighlight = key
        let fit = view.scaleFactorForSizeToFit
        if fit > 0 {
            view.autoScales = false
            view.scaleFactor = min(fit * 2.5, view.maxScaleFactor)
        }
        view.go(to: box.insetBy(dx: -24, dy: -24), on: page)
    }

    // MARK: Loading

    /// Opens a document's file as a PDF; a photo becomes a one-page PDF.
    @concurrent
    static func load(bookmark: Data?, fileName: String) async throws -> PDFDocument {
        guard let bookmark, let url = FileAccess.resolve(bookmark)?.url else { throw CocoaError(.fileNoSuchFile) }
        let data = try FileAccess.read(url)
        if let pdf = PDFDocument(data: data), pdf.pageCount > 0 { return pdf }
        guard let image = try PageReader.renderPage(0, of: data, fileName: fileName), let page = PDFPage(image: UIImage(cgImage: image)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pdf = PDFDocument()
        pdf.insert(page, at: 0)
        return pdf
    }
}

/// The preview pane on a document's screen. A document with a document number shows its file only after
/// Face ID, because the file shows the number in full. The screen's Face ID unlock covers the file and the
/// numbers together.
struct PreviewPane: View {
    let document: SourceDocument
    let highlight: (page: Int, rect: CGRect)?
    @Binding var isExpanded: Bool
    let reveal: RevealState
    let onUnlock: () -> Void

    @State private var pdf: PDFDocument?
    @State private var errorMessage: String?

    private var isUnlocked: Bool { reveal.isUnlocked }

    private var needsFaceID: Bool {
        document.facts.contains { $0.isSensitive || $0.cropRevealsNumber }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            if needsFaceID, !isUnlocked {
                VStack(spacing: 10) {
                    Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(Color.dsTint)
                    Text("Locked. Unlock to see this document and its numbers.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Unlock", systemImage: "faceid", action: onUnlock)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
                .padding()
            } else if let pdf {
                DocumentPreview(pdf: pdf, highlight: highlight)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            } else {
                ProgressView("Opening the file…").font(.footnote)
            }
        }
        .overlay(alignment: .topTrailing) {
            if pdf != nil, !needsFaceID || isUnlocked {
                Button(isExpanded ? "Show less" : "Show more", systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .padding(8)
            }
        }
        .task(id: document.bookmark) {
            do {
                pdf = try await DocumentPreview.load(bookmark: document.bookmark, fileName: document.fileName)
            } catch {
                errorMessage = "The file can’t be opened. It may have been moved or deleted."
            }
        }
        .animation(.easeOut(duration: 0.2), value: isUnlocked)
    }
}
