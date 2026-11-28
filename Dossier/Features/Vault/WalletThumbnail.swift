import SwiftUI
import UIKit

/// Small pictures of a document's first page, for the cards in the wallet. Rendered off the main actor and
/// kept in memory by content hash, so a card draws its picture once.
nonisolated final class WalletThumbnails: @unchecked Sendable {
    static let shared = WalletThumbnails()

    /// Pixel size of the longest side. Big enough for the focused card on a 3x screen.
    static let maxPixelSize: CGFloat = 320

    // NSCache is thread-safe.
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 60
    }

    func cached(_ hash: String) -> UIImage? {
        cache.object(forKey: hash as NSString)
    }

    /// The first page of the file, made small. Nil when the file is missing or can't be read.
    func thumbnail(hash: String, bookmark: Data?, fileName: String) async -> UIImage? {
        if let image = cached(hash) { return image }
        guard let image = await Self.render(bookmark: bookmark, fileName: fileName) else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }

    @concurrent
    private static func render(bookmark: Data?, fileName: String) async -> UIImage? {
        guard let bookmark, let url = FileAccess.resolve(bookmark)?.url,
              let data = try? FileAccess.read(url),
              let page = try? PageReader.renderPage(0, of: data, fileName: fileName) else { return nil }
        let image = UIImage(cgImage: page)
        let scale = min(maxPixelSize / max(image.size.width, image.size.height), 1)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return image.preparingThumbnail(of: size) ?? image
    }
}

/// A document's first page in a small rounded frame, or its kind's symbol when there's no file.
struct WalletThumbnail: View {
    let document: SourceDocument
    var width: CGFloat = 58
    var height: CGFloat = 72

    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                shape.fill(.white.opacity(0.18))
                Image(systemName: document.kind.symbol)
                    .font(.system(size: width * 0.4, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .accessibilityHidden(true)
        .task(id: document.contentHash) {
            let hash = document.contentHash
            image = WalletThumbnails.shared.cached(hash)
            guard image == nil else { return }
            image = await WalletThumbnails.shared.thumbnail(hash: hash, bookmark: document.bookmark, fileName: document.fileName)
        }
    }
}
