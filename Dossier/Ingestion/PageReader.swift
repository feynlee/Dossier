import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// One rendered page with what Vision read from it.
nonisolated struct ReadPage: Sendable {
    var image: CGImage
    var lines: [String]
    /// Where each line sits on the page, normalized to 0–1 with a top-left origin. Parallel to `lines`.
    var boxes: [CGRect]
    /// Decoded PDF417 payloads (driver's licence barcodes).
    var barcodes: [String]
}

/// Renders a document's pages and reads them locally with Vision. The text is used to verify what Private
/// Cloud Compute extracts, and is what gets sent to PCC if it can't take page images.
nonisolated enum PageReader {
    /// Enough for any ID card or passport scan and the first pages of a lease, while keeping requests small.
    static let maxPages = 6
    private static let maxPixelDimension: CGFloat = 2200

    @concurrent
    static func read(_ data: Data, fileName: String) async throws -> [ReadPage] {
        var pages: [ReadPage] = []
        for image in try render(data, fileName: fileName) {
            async let text = recognizeText(in: image)
            async let barcodes = detectBarcodes(in: image)
            let (lines, boxes) = try await text
            pages.append(ReadPage(image: image, lines: lines, boxes: boxes, barcodes: (try? await barcodes) ?? []))
        }
        return pages
    }

    // MARK: Rendering

    static func render(_ data: Data, fileName: String) throws -> [CGImage] {
        if fileName.lowercased().hasSuffix(".pdf") || data.starts(with: Data("%PDF".utf8)) {
            guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            return (0..<min(document.pageCount, maxPages)).compactMap { index in
                document.page(at: index).flatMap(renderPDFPage)
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return [image]
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
