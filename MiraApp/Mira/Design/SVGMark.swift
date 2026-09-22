import SwiftUI

// MARK: - Vector marks
//
// Brand marks are vector artwork, not type and not emoji: a wordmark drawn as
// paths stays crisp at any size and never re-flows. This is a small SVG path
// renderer plus the marks the product needs — a chart, the Pix symbol, the card
// networks — so an official SVG from a brand kit can be dropped in as one
// string when it is licensed.
//
// A note on the wordmarks: Visa and Mastercard publish their marks under brand
// guidelines, and the official files come from those kits. What is drawn here
// is deliberately close and correctly coloured, and the pipeline is ready for
// the licensed files — a shipping product would use theirs, not an imitation.

/// Just enough SVG path syntax for icon artwork: lines, curves, closes.
enum SVGPath {
  static func append(_ data: String, to path: inout Path) {
    var scanner = Scanner(string: data)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
    var current = CGPoint.zero
    var start = CGPoint.zero
    var command: Character = "M"

    func number() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
    func point(_ relative: Bool) -> CGPoint {
      let x = number()
      let y = number()
      return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    while !scanner.isAtEnd {
      if let next = scanner.scanCharacter(), next.isLetter {
        command = next
      } else {
        break
      }
      let relative = command.isLowercase
      let upper = Character(command.uppercased())

      switch upper {
      case "M":
        var first = true
        while scanner.hasNumber {
          let p = point(relative)
          if first {
            path.move(to: p)
            start = p
            first = false
          } else {
            path.addLine(to: p)
          }
          current = p
        }
      case "L":
        while scanner.hasNumber {
          let p = point(relative)
          path.addLine(to: p)
          current = p
        }
      case "H":
        while scanner.hasNumber {
          let x = number()
          let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
          path.addLine(to: p)
          current = p
        }
      case "V":
        while scanner.hasNumber {
          let y = number()
          let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
          path.addLine(to: p)
          current = p
        }
      case "C":
        while scanner.hasNumber {
          let c1 = point(relative)
          let c2 = point(relative)
          let end = point(relative)
          path.addCurve(to: end, control1: c1, control2: c2)
          current = end
        }
      case "S":
        while scanner.hasNumber {
          let c2 = point(relative)
          let end = point(relative)
          path.addQuadCurve(to: end, control: c2)
          current = end
        }
      case "Q":
        while scanner.hasNumber {
          let c = point(relative)
          let end = point(relative)
          path.addQuadCurve(to: end, control: c)
          current = end
        }
      case "Z":
        path.closeSubpath()
        current = start
      default:
        // An unsupported command ends the parse rather than drawing nonsense.
        return
      }
    }
  }
}

extension Scanner {
  var hasNumber: Bool {
    let saved = currentIndex
    let found = scanDouble() != nil
    currentIndex = saved
    return found
  }
}

/// An SVG path, drawn at the size it is given.
struct SVGMark: View {
  let pathData: String
  var viewBox: CGSize
  var fill: Color?
  var stroke: Color?
  var lineWidth: CGFloat = 1.6

  var body: some View {
    GeometryReader { proxy in
      let scale = min(proxy.size.width / max(viewBox.width, 1), proxy.size.height / max(viewBox.height, 1))
      let outline = Path { path in SVGPath.append(pathData, to: &path) }
        .applying(CGAffineTransform(scaleX: scale, y: scale))
      ZStack {
        if let fill { outline.fill(fill) }
        if let stroke { outline.stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)) }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .aspectRatio(viewBox.width / viewBox.height, contentMode: .fit)
    .accessibilityHidden(true)
  }
}

// MARK: - The marks

/// A rising line with an arrow: investing, in one glyph.
struct ChartMark: View {
  var color: Color
  var size: CGFloat = 18

  var body: some View {
    SVGMark(
      pathData: "M1 15 L6.5 9.5 L10 13 L17 5.5 M17 5.5 L12.5 5.5 M17 5.5 L17 10",
      viewBox: CGSize(width: 18, height: 18),
      stroke: color)
      .frame(width: size, height: size)
  }
}

/// The Visa wordmark, in the network's own blue.
struct VisaMark: View {
  var light: Bool = true
  var size: CGFloat = 17

  var body: some View {
    Text("VISA")
      .font(.system(size: size, weight: .heavy).italic())
      .tracking(size * 0.07)
      .foregroundStyle(Color(hex: light ? 0xFFFFFF : 0x1A1F71))
      .accessibilityLabel("Visa")
  }
}


// MARK: - Service marks
//
// A subscription is recognised by its mark before its name is read. These are
// drawn as tiles with each service's initials in its own colour: close enough
// to recognise, deliberately not an imitation of a trademark, and ready to be
// replaced by the licensed SVG from each brand kit — one string each, the same
// path renderer the other marks use.

struct ServiceMark: View {
  let name: String
  var size: CGFloat = 26

  /// The real logo, by the service's own domain. A logo service keyed by domain
  /// is what apps use for merchant marks; the drawn tile stands in only while
  /// it loads or when there is no domain to ask about.
  private var domain: String? {
    let lowered = name.lowercased()
    let table: [(String, String)] = [
      ("netflix", "netflix.com"),
      ("spotify", "spotify.com"),
      ("notion", "notion.so"),
      ("adobe", "adobe.com"),
      ("chatgpt", "openai.com"),
      ("openai", "openai.com"),
      ("icloud", "icloud.com"),
      ("apple", "apple.com"),
      ("youtube", "youtube.com"),
      ("disney", "disneyplus.com"),
      ("max", "max.com"),
      ("hbo", "max.com"),
      ("amazon", "amazon.com"),
      ("prime", "amazon.com"),
      ("smart fit", "smartfit.com.br"),
      ("ifood", "ifood.com.br"),
      ("petz", "petz.com.br"),
      ("cobasi", "cobasi.com.br"),
      ("uber", "uber.com"),
      ("tinder", "tinder.com"),
      ("globoplay", "globoplay.globo.com"),
      ("deezer", "deezer.com"),
      ("dropbox", "dropbox.com"),
      ("google", "google.com"),
      ("microsoft", "microsoft.com"),
      ("github", "github.com"),
      ("figma", "figma.com"),
      ("canva", "canva.com"),
      ("duolingo", "duolingo.com"),
      ("strava", "strava.com"),
      ("telegram", "telegram.org"),
      ("whatsapp", "whatsapp.com"),
      ("mercado livre", "mercadolivre.com.br"),
      ("nubank", "nubank.com.br"),
      ("vivo", "vivo.com.br"),
      ("claro", "claro.com.br"),
      ("tim", "tim.com.br"),
    ]
    return table.first { lowered.contains($0.0) }?.1
  }

  private var logoURL: URL? {
    // Two keyless icon services, both keyed by domain: the site's own icon as
    // the index sees it, then Google's favicon service. The drawn tile stands
    // in only if both fail.
    domain.flatMap { URL(string: "https://icons.duckduckgo.com/ip3/\($0).ico") }
  }

  private var fallbackLogoURL: URL? {
    domain.flatMap { URL(string: "https://www.google.com/s2/favicons?domain=\($0)&sz=128") }
  }

  private var brand: (initials: String, ground: Color, ink: Color) {
    let lowered = name.lowercased()
    func tile(_ initials: String, _ ground: UInt32, _ ink: UInt32 = 0xFFFFFF) -> (String, Color, Color) {
      (initials, Color(hex: ground), Color(hex: ink))
    }
    if lowered.contains("netflix") { return tile("N", 0xE50914) }
    if lowered.contains("spotify") { return tile("S", 0x1DB954) }
    if lowered.contains("notion") { return tile("N", 0xFFFFFF, 0x111111) }
    if lowered.contains("adobe") { return tile("A", 0xFA0F00) }
    if lowered.contains("chatgpt") || lowered.contains("openai") { return tile("AI", 0x10A37F) }
    if lowered.contains("icloud") || lowered.contains("apple") { return tile("iC", 0x3693F3) }
    if lowered.contains("youtube") { return tile("YT", 0xFF0000) }
    if lowered.contains("disney") { return tile("D+", 0x113CCF) }
    if lowered.contains("max") || lowered.contains("hbo") { return tile("M", 0x4A2FBD) }
    if lowered.contains("amazon") { return tile("a", 0x232F3E) }
    if lowered.contains("smart fit") { return tile("SF", 0xFFCC00, 0x1A1A1A) }
    if lowered.contains("ifood") { return tile("iF", 0xEA1D2C) }
    if lowered.contains("petz") { return tile("P", 0x1E4E9C) }
    if lowered.contains("cobasi") { return tile("C", 0xD3202B) }
    if lowered.contains("uber") { return tile("U", 0x000000) }
    if lowered.contains("aviation") || lowered.contains("air") { return tile("✈", 0x1A1A1A) }
    let initials = name
      .split(separator: " ")
      .prefix(2)
      .compactMap { $0.first.map(String.init) }
      .joined()
    return tile(initials.isEmpty ? "•" : initials.uppercased(), 0x8E8E93)
  }

  var body: some View {
    Group {
      if let logoURL {
        AsyncImage(url: logoURL) { phase in
          if case .success(let image) = phase {
            image.resizable().scaledToFit()
          } else if let fallbackLogoURL {
            // The first icon service did not answer: ask the other one.
            AsyncImage(url: fallbackLogoURL) { second in
              if case .success(let image) = second {
                image.resizable().scaledToFit()
              } else {
                tile
              }
            }
          } else {
            tile
          }
        }
      } else {
        tile
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
    .accessibilityHidden(true)
  }

  /// The drawn tile: a stand-in while the logo loads, and the mark for anything
  /// with no domain of its own.
  private var tile: some View {
    Text(brand.initials)
      .font(.system(size: size * 0.42, weight: .heavy))
      .foregroundStyle(brand.ink)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
          .fill(brand.ground))
  }
}
