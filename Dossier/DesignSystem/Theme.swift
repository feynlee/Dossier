import SwiftUI
import UIKit

/// Dossier's color tokens (from the design system). Apple system colors cover backgrounds, labels and
/// separators; these are the tint and the one warning color.
extension Color {
    /// The one accent: links, icons, verified badges.
    static let dsTint = Color(light: 0x4B45C6, dark: 0x8E8BFF)
    /// Filled buttons, the selected segment and badge discs. Pair with white text.
    static let dsTintFill = Color(light: 0x4B45C6, dark: 0x5E5CE6)
    /// Icon tiles and timeline bands.
    static let dsTintSoft = Color(light: 0xE9E9F8, dark: 0x29284D)
    /// Expiring soon and gaps in history only, always with a clock or warning symbol.
    static let dsWarning = Color(light: 0xB25000, dark: 0xFF9F0A)
    static let dsOnWarning = Color(light: 0xFFFFFF, dark: 0x000000)
    /// The "needs review" badge disc.
    static let dsBadgeNeutral = Color(light: 0x6E6E73, dark: 0x98989F)
    /// Cells and cards, for the ring around badges.
    static let dsSurface = Color(uiColor: .secondarySystemGroupedBackground)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Font {
    /// Document numbers and dates: SF Mono, so O/0 and I/1 can't be confused.
    static let dsFieldValue = Font.system(.body, design: .monospaced).weight(.medium)
}
