import SwiftUI

/// The one status badge a row can carry.
nonisolated enum TileBadge: Sendable {
    case verified
    case expiring
    case review
    case reading
}

/// A document or fact icon: a tint-soft tile with an SF Symbol, and its status as a small badge disc on the
/// bottom-right corner. This replaces colored pills everywhere in the app.
struct BadgedTile: View {
    let symbol: String
    let badge: TileBadge?
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(Color.dsTintSoft)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.47, weight: .medium))
                    .foregroundStyle(Color.dsTint)
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

/// A row: badged tile, title, subtitle.
struct TileRow: View {
    let symbol: String
    let badge: TileBadge?
    let title: String
    var subtitle: String?
    var subtitleIsWarning = false

    var body: some View {
        HStack(spacing: 12) {
            BadgedTile(symbol: symbol, badge: badge)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    HStack(spacing: 4) {
                        if subtitleIsWarning { Image(systemName: "clock") }
                        Text(subtitle)
                    }
                    .font(.subheadline)
                    .foregroundStyle(subtitleIsWarning ? Color.dsWarning : .secondary)
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
    }
}
