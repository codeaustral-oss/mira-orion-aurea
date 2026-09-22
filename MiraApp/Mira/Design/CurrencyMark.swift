import SwiftUI

// MARK: - Currency mark
//
// Currency is not a flag. A dollar account is not the United States, a euro
// balance is not the eurozone, and a stablecoin has no country at all — so the
// marks here are drawn per asset rather than borrowed from a country.
//
// They are drawn in code rather than shipped as images: a mark stays crisp at
// any size, takes the active brand's colour, and cannot fall out of date. And
// they are never emoji: a colour glyph rendered by another platform's font is
// the one thing on these screens that cannot be art-directed.

/// A hexagon, for the stablecoins. A coin with no country gets a shape rather
/// than a border.
struct Hexagon: Shape {
  func path(in rect: CGRect) -> Path {
    let inset = rect.width * 0.18
    let mid = rect.midY
    let top = rect.minY + inset
    let bottom = rect.maxY - inset
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: mid))
    path.addLine(to: CGPoint(x: rect.minX + inset, y: top))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: top))
    path.addLine(to: CGPoint(x: rect.maxX, y: mid))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: bottom))
    path.addLine(to: CGPoint(x: rect.minX + inset, y: bottom))
    path.closeSubpath()
    return path
  }
}

/// One currency, as a mark.
///
/// `filled` gives the disc a tinted ground, which is what a list row wants.
/// `plain` draws only the glyph, for use inside another surface.
struct CurrencyMark: View {
  let asset: Asset
  var size: CGFloat = 40
  var filled: Bool = true

  @Environment(\.brand) private var brand

  var body: some View {
    ZStack {
      if filled {
        Circle().fill(brand.accentTint)
      }

      if asset.kind == .stablecoin {
        Hexagon()
          .stroke(brand.accent.opacity(0.5), lineWidth: max(1, size * 0.028))
          .frame(width: size * 0.66, height: size * 0.66)
      }

      Text(asset.markGlyph)
        .font(
          .system(
            size: size * (asset.markGlyph.count > 1 ? 0.38 : 0.46),
            weight: .medium,
            design: brand.serifDisplay ? .serif : .default
          )
        )
        .foregroundStyle(brand.accent)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, size * 0.1)

      if filled {
        Circle().strokeBorder(brand.hairline, lineWidth: 1)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

extension Asset {
  /// The glyph the mark is drawn with. Fiat uses its own symbol; a stablecoin
  /// uses the same dollar form as the currency it tracks, inside the hexagon,
  /// except Tether, which has its own mark.
  var markGlyph: String {
    switch code {
    case "USD": return "$"
    case "BRL": return "R$"
    case "EUR": return "€"
    case "USDC": return "$"
    case "USDT": return "₮"
    default: return String(code.prefix(2))
    }
  }

  /// The currency symbol a person would write in front of an amount. Fiat has
  /// one; a token does not, which is why the code is shown instead.
  var displaySymbol: String {
    kind == .stablecoin ? "" : symbol
  }
}

// MARK: - Country mark

/// A country, as a mark.
///
/// The ISO code in a quiet disc. It says which country without borrowing a flag
/// emoji, and it stays legible at 22pt.
struct CountryMark: View {
  let country: Country
  var size: CGFloat = 28

  @Environment(\.brand) private var brand

  var body: some View {
    ZStack {
      Circle().fill(brand.surface)
      Text(country.code)
        .font(.system(size: size * 0.36, weight: .medium))
        .tracking(0.4)
        .foregroundStyle(brand.textSecondary)
      Circle().strokeBorder(brand.hairline, lineWidth: 1)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
