import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// One rendered page with what Vision read from it.
nonisolated struct ReadPage: Sendable {
    /// The rendered page, kept only for the first `PageReader.maxImagePages` pages (the ones sent to the model
    /// as images). Later pages contribute their text only.
    var image: CGImage?
    var lines: [String]
    /// Where each line sits on the page, normalized to 0–1 with a top-left origin. Parallel to `lines`.
    var boxes: [CGRect]
    /// Decoded PDF417 payloads (driver's licence barcodes).
    var barcodes: [String]
}

/// Renders a document's pages and reads them locally with Vision. The text is used to verify what Private
/// Cloud Compute extracts, and is what gets sent to PCC if it can't take page images.
nonisolated enum PageReader {
    /// Pages whose text is read. Covers long leases and multi-page notices.
    static let maxPages = 40
    /// Pages also sent to the model as images: enough for any card, passport or notice's key pages, while
    /// keeping requests small. Every page's text is sent.
    static let maxImagePages = 6
    private static let maxPixelDimension: CGFloat = 2200

    @concurrent
    static func read(_ data: Data, fileName: String) async throws -> [ReadPage] {
        var pages: [ReadPage] = []
        // One page at a time, so a 40-page lease never holds 40 full-size images in memory.
        for index in 0..<(try pageCount(data, fileName: fileName)) {
            guard let image = try renderPage(index, of: data, fileName: fileName) else { continue }
            async let text = recognizeText(in: image)
            async let barcodes = detectBarcodes(in: image)
            let (lines, boxes) = try await text
            pages.append(ReadPage(
                image: index < maxImagePages ? image : nil,
                lines: lines, boxes: boxes, barcodes: (try? await barcodes) ?? []
            ))
        }
        return pages
    }

    // MARK: Rendering

    private static func isPDF(_ data: Data, fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".pdf") || data.starts(with: Data("%PDF".utf8))
    }

    static func pageCount(_ data: Data, fileName: String) throws -> Int {
        guard isPDF(data, fileName: fileName) else { return 1 }
        guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return min(document.pageCount, maxPages)
    }

    /// Renders one page (0-based). Images have a single page.
    static func renderPage(_ index: Int, of data: Data, fileName: String) throws -> CGImage? {
        if isPDF(data, fileName: fileName) {
            guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            return document.page(at: index).flatMap(renderPDFPage)
        }
        guard index == 0, let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    private static func renderPDFPage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxPixelDimension / max(bounds.width, bounds.height), 3)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: Vision

    static func recognizeText(in image: CGImage) async throws -> (lines: [String], boxes: [CGRect]) {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" document numbers and MRZ lines into words; keep the raw reading.
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image)
        // Vision's origin is bottom-left: sort top to bottom, then left to right.
        let sorted = observations.sorted { lhs, rhs in
            let dy = lhs.boundingBox.origin.y - rhs.boundingBox.origin.y
            return abs(dy) > 0.01 ? dy > 0 : lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
        }
        var lines: [String] = [], boxes: [CGRect] = []
        for observation in sorted {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let box = observation.boundingBox
            lines.append(text)
            boxes.append(CGRect(x: box.origin.x, y: 1 - box.origin.y - box.height, width: box.width, height: box.height))
        }
        return (lines, boxes)
    }

    static func detectBarcodes(in image: CGImage) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.pdf417]
        return try await request.perform(on: image).compactMap(\.payloadString)
    }
}
