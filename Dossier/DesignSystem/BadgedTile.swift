import SwiftUI

/// The one status badge a row can carry.
nonisolated enum TileBadge: Sendable {
    case verified
    case expiring
    case review
    case reading
    /// Past the expiry date printed on it.
    case expired
    /// Replaced by a newer version of itself.
    case renewed

    /// Kept for your records rather than in use: the tile is drawn muted.
    var isEnded: Bool { self == .expired || self == .renewed }
}

/// A document or fact icon: a tint-soft tile with an SF Symbol, and its status as a small badge disc on the
/// bottom-right corner. This replaces colored pills everywhere in the app.
struct BadgedTile: View {
    let symbol: String
    let badge: TileBadge?
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(badge?.isEnded == true ? Color(uiColor: .tertiarySystemFill) : Color.dsTintSoft)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.47, weight: .medium))
                    .foregroundStyle(badge?.isEnded == true ? Color.secondary : Color.dsTint)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    BadgeDisc(badge: badge)
                        .offset(x: 5, y: 5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.map(Self.accessibilityLabel) ?? "")
    }

    nonisolated static func accessibilityLabel(_ badge: TileBadge) -> String {
        switch badge {
        case .verified: "Verified"
        case .expiring: "Expiring soon"
        case .review: "Needs review"
        case .reading: "Reading"
        case .expired: "Expired"
        case .renewed: "Renewed"
        }
    }
}

private struct BadgeDisc: View {
    let badge: TileBadge

    var body: some View {
        Group {
            switch badge {
            case .verified: disc(Color.dsTintFill, glyph: "checkmark", glyphColor: .white)
            case .expiring: disc(Color.dsWarning, glyph: "clock", glyphColor: Color.dsOnWarning)
            case .review: disc(Color.dsBadgeNeutral, glyph: "questionmark", glyphColor: Color.dsSurface)
            case .expired: disc(Color.dsExpired, glyph: "xmark", glyphColor: .white)
            case .renewed: disc(Color.dsRenewed, glyph: TileBadge.renewedSymbol, glyphColor: .white)
            case .reading:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.dsSurface).frame(width: 18, height: 18))
            }
        }
    }

    private func disc(_ fill: Color, glyph: String, glyphColor: Color) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 14, height: 14)
            .overlay {
                Image(systemName: glyph)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(glyphColor)
            }
            .padding(2)
            .background(Circle().fill(Color.dsSurface))
    }
}

extension TileBadge {
    /// The symbol that marks a document replaced by its renewal, on its badge and next to its end date.
    nonisolated static let renewedSymbol = "arrow.triangle.2.circlepath"
}

/// How a row's subtitle is drawn: plain, or in a status color with its symbol in front.
enum SubtitleTone {
    case plain
    /// Expiring soon, a gap, a problem: warning color and a clock.
    case warning
    /// Expired: red and an xmark.
    case expired
    /// Replaced by a renewal: teal and the renew arrows.
    case renewed

    var symbol: String? {
        switch self {
        case .plain: nil
        case .warning: "clock"
        case .expired: "xmark.circle"
        case .renewed: TileBadge.renewedSymbol
        }
    }

    var color: Color {
        switch self {
        case .plain: .secondary
        case .warning: .dsWarning
        case .expired: .dsExpired
        case .renewed: .dsRenewed
        }
    }
}

/// A row: badged tile, title, subtitle.
struct TileRow: View {
    let symbol: String
    let badge: TileBadge?
    let title: String
    var subtitle: String?
    var subtitleTone: SubtitleTone = .plain

    init(symbol: String, badge: TileBadge?, title: String, subtitle: String? = nil, subtitleIsWarning: Bool = false) {
        self.init(symbol: symbol, badge: badge, title: title, subtitle: subtitle, subtitleTone: subtitleIsWarning ? .warning : .plain)
    }

    init(symbol: String, badge: TileBadge?, title: String, subtitle: String?, subtitleTone: SubtitleTone) {
        self.symbol = symbol
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.subtitleTone = subtitleTone
    }

    var body: some View {
        HStack(spacing: 12) {
            BadgedTile(symbol: symbol, badge: badge)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    HStack(spacing: 4) {
                        if let mark = subtitleTone.symbol { Image(systemName: mark) }
                        Text(subtitle)
                    }
                    .font(.subheadline)
                    .foregroundStyle(subtitleTone.color)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    List {
        TileRow(symbol: "person.text.rectangle", badge: .verified, title: "Passport", subtitle: "Expires 14 Mar 2029")
        TileRow(symbol: "car", badge: .expiring, title: "Driver’s licence", subtitle: "Expires 30 Jan 2027", subtitleIsWarning: true)
        TileRow(symbol: "doc.text", badge: .review, title: "I-797 notice", subtitle: "Received 3 Jan 2024")
        TileRow(symbol: "airplane", badge: .reading, title: "I-94 travel history", subtitle: "Reading…")
        TileRow(symbol: "person.text.rectangle", badge: .renewed, title: "Passport", subtitle: "Renewed · ended 2 Apr 2019", subtitleTone: .renewed)
        TileRow(symbol: "car", badge: .expired, title: "Driver’s licence", subtitle: "Expired 30 Jan 2021", subtitleTone: .expired)
    }
}
