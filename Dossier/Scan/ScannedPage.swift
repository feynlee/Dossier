import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One page of a scan: the photo as taken, where the page is in it, and how it's turned. The flat page is
/// made from these, so the crop can be changed later. Images are kept in memory as JPEG only and never
/// written anywhere except the saved PDF.
nonisolated struct ScannedPage: Identifiable, Sendable {
    let id = UUID()
    /// The photo, upright, as JPEG.
    var photo: Data
    var photoSize: CGSize
    var outline: PageOutline
    /// Quarter turns clockwise.
    var turns = 0
    /// The flat, cropped page as JPEG, made from the above.
    var page: Data

    /// Longest side kept: sharp enough to read small print, small enough to keep many pages in memory.
    static let maxPhotoSide: CGFloat = 3000

    /// Makes a page from a camera photo: turns it upright, scales it down, finds the page (or uses
    /// `fallback`, the outline seen in the live preview), and flattens it.
    static func make(from image: UIImage, fallback: PageOutline?) -> ScannedPage? {
        guard let upright = upright(image) else { return nil }
        let size = CGSize(width: upright.width, height: upright.height)
        let outline = PageDetector.detect(in: upright)
            ?? fallback.map { PageOutline(corners: $0.corners, frameSize: size) }
            ?? .whole(size)
        guard let photo = jpeg(upright, quality: 0.85) else { return nil }
        var page = ScannedPage(photo: photo, photoSize: size, outline: outline, page: Data())
        guard page.render(from: upright) else { return nil }
        return page
    }

    /// Makes the flat page again after the outline or turns changed.
    mutating func rerender() {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        _ = render(from: image)
    }

    private mutating func render(from image: CGImage) -> Bool {
        let ci = CIImage(cgImage: image)
        let w = ci.extent.width, h = ci.extent.height
        // Core Image's origin is the bottom-left.
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ci
        filter.topLeft = point(outline.topLeft)
        filter.topRight = point(outline.topRight)
        filter.bottomRight = point(outline.bottomRight)
        filter.bottomLeft = point(outline.bottomLeft)
        guard var flat = filter.outputImage else { return false }
        if turns % 4 != 0 {
            flat = flat.oriented([.up, .right, .down, .left][turns % 4])
        }
        flat = flat.transformed(by: CGAffineTransform(translationX: -flat.extent.minX, y: -flat.extent.minY))
        guard let cg = Self.context.createCGImage(flat, from: flat.extent), let data = Self.jpeg(cg, quality: 0.8) else { return false }
        page = data
        return true
    }

    var pageImage: UIImage? { UIImage(data: page) }
    var photoImage: UIImage? { UIImage(data: photo) }

    // MARK: Helpers

    private static let context = CIContext()

    /// The photo with its orientation applied and its longest side at most `maxPhotoSide`.
    private static func upright(_ image: UIImage) -> CGImage? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxPhotoSide / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

nonisolated enum ScanPDF {
    /// A PDF with one page per scanned page, each the width of US Letter (8.5 in) with the page's own
    /// proportions. The JPEGs are embedded as they are, so the file stays small.
    static func make(_ pages: [ScannedPage]) -> Data? {
        make(jpegs: pages.map(\.page))
    }

    /// A photo as a one-page PDF, upright and the same width as scanned pages.
    static func make(photo data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, ScannedPage.maxPhotoSide / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        guard let upright = UIGraphicsImageRenderer(size: size, format: format).image(actions: { _ in image.draw(in: CGRect(origin: .zero, size: size)) }).cgImage,
              let jpeg = ScannedPage.jpeg(upright, quality: 0.85) else { return nil }
        return make(jpegs: [jpeg])
    }

    static func make(jpegs: [Data]) -> Data? {
        let pages = jpegs
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "Dossier"] as CFDictionary) else { return nil }
        for page in pages {
            guard let provider = CGDataProvider(data: page as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            let width: CGFloat = 612
            var box = CGRect(x: 0, y: 0, width: width, height: width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return pages.isEmpty ? nil : data as Data
    }
}
