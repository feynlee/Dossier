import CoreGraphics
import SwiftUI
import UIKit

/// The strip of the original page a value was read from, re-rendered from the file in your folder. Nothing
/// from the page is stored in the vault: only the line's position.
struct SourceCropView: View {
    let relativePath: String
    let page: Int
    let rect: CGRect

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dsTint, lineWidth: 1.5))
                    .accessibilityLabel("The line on page \(page) this value was read from")
            } else if !failed {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .systemGroupedBackground)).frame(height: 44)
                    .overlay(ProgressView())
            }
        }
        .task(id: "\(relativePath)#\(page)#\(rect.debugDescription)") {
            image = await Self.crop(relativePath: relativePath, page: page, rect: rect)
            failed = image == nil
        }
    }

    @concurrent
    static func crop(relativePath: String, page: Int, rect: CGRect) async -> UIImage? {
        guard !relativePath.isEmpty,
              let data = try? FolderAccess.read(relativePath: relativePath),
              let pages = try? PageReader.render(data, fileName: relativePath),
              pages.indices.contains(page - 1) else { return nil }
        let image = pages[page - 1]
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Pad around the line so the value is shown with a little of its surroundings.
        let padded = CGRect(
            x: (rect.minX - 0.04) * width,
            y: (rect.minY - rect.height * 0.8) * height,
            width: (rect.width + 0.08) * width,
            height: rect.height * 2.6 * height
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = image.cropping(to: padded.integral) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
