import SwiftUI

// MARK: - The constellation

/// A star, positioned from its real right ascension and declination.
///
/// Orion is drawn from actual coordinates rather than an artist's impression,
/// because the shape is the brand. If the belt sits at the wrong angle it reads
/// as a random scatter of dots instead of the one constellation most people can
/// name on sight.
struct Star: Identifiable, Sendable {
  let id: String
  let name: String
  let designation: String
  /// Right ascension in hours.
  let ra: Double
  /// Declination in degrees.
  let dec: Double
  /// Apparent magnitude. Lower is brighter.
  let magnitude: Double

  init(_ id: String, _ name: String, _ designation: String, ra: Double, dec: Double, magnitude: Double) {
    self.id = id
    self.name = name
    self.designation = designation
    self.ra = ra
    self.dec = dec
    self.magnitude = magnitude
  }
}

enum OrionConstellation {
  // RA in hours, Dec in degrees, magnitude from the standard catalogues.
  static let betelgeuse = Star("betelgeuse", "Betelgeuse", "α Ori", ra: 5.919, dec: 7.407, magnitude: 0.42)
  static let meissa = Star("meissa", "Meissa", "λ Ori", ra: 5.585, dec: 9.934, magnitude: 3.39)
  static let bellatrix = Star("bellatrix", "Bellatrix", "γ Ori", ra: 5.418, dec: 6.350, magnitude: 1.64)
  static let alnitak = Star("alnitak", "Alnitak", "ζ Ori", ra: 5.679, dec: -1.943, magnitude: 1.74)
  static let alnilam = Star("alnilam", "Alnilam", "ε Ori", ra: 5.604, dec: -1.202, magnitude: 1.69)
  static let mintaka = Star("mintaka", "Mintaka", "δ Ori", ra: 5.533, dec: -0.299, magnitude: 2.25)
  static let saiph = Star("saiph", "Saiph", "κ Ori", ra: 5.796, dec: -9.670, magnitude: 2.07)
  static let rigel = Star("rigel", "Rigel", "β Ori", ra: 5.242, dec: -8.202, magnitude: 0.13)
  static let hatysa = Star("hatysa", "Hatysa", "ι Ori", ra: 5.591, dec: -5.910, magnitude: 2.77)

  static let all: [Star] = [
    betelgeuse, meissa, bellatrix, alnitak, alnilam, mintaka, saiph, rigel, hatysa,
  ]

  static let belt: [Star] = [mintaka, alnilam, alnitak]

  /// Segments that make the familiar figure.
  static let segments: [(String, String)] = [
    ("betelgeuse", "alnitak"),
    ("bellatrix", "mintaka"),
    ("betelgeuse", "bellatrix"),
    ("betelgeuse", "meissa"),
    ("bellatrix", "meissa"),
    ("mintaka", "alnilam"),
    ("alnilam", "alnitak"),
    ("alnitak", "saiph"),
    ("mintaka", "rigel"),
    ("alnitak", "hatysa"),
  ]

  static func star(_ id: String) -> Star? {
    all.first { $0.id == id }
  }
}

/// Maps sky coordinates to a unit square. Right ascension runs backwards across
/// the sky, which is the detail that decides whether the figure is recognisable
/// or mirrored.
struct SkyProjection: Sendable {
  var raRange: ClosedRange<Double> = 5.20...5.96
  var decRange: ClosedRange<Double> = -10.2...10.4

  func point(for star: Star) -> UnitPoint {
    UnitPoint(
      x: (raRange.upperBound - star.ra) / (raRange.upperBound - raRange.lowerBound),
      y: (decRange.upperBound - star.dec) / (decRange.upperBound - decRange.lowerBound)
    )
  }
}

// MARK: - Stations

/// The four places in Orion. Each is anchored to a real star.
enum OrionStation: String, CaseIterable, Identifiable, Sendable {
  case accounts
  case move
  case mira
  case you

  var id: String { rawValue }

  var anchor: Star {
    switch self {
    case .accounts: return OrionConstellation.betelgeuse
    case .move: return OrionConstellation.alnilam
    case .mira: return OrionConstellation.hatysa
    case .you: return OrionConstellation.rigel
    }
  }

  var title: String {
    switch self {
    case .accounts: return "Accounts"
    case .move: return "Move"
    case .mira: return "Mira"
    case .you: return "You"
    }
  }

  /// How far the camera moves in when this station is in focus.
  var zoom: Double {
    switch self {
    case .accounts: return 1.0
    case .move: return 1.28
    case .mira: return 1.46
    case .you: return 1.10
    }
  }
}

// MARK: - The field

/// Orion, drawn as a diagram.
///
/// The figure is black line work on paper, the way it appears on a star chart:
/// a thin unbroken path, filled dots for the stars, and nothing else. The four
/// stations are the four brightest points, and moving between them pans and zooms
/// the chart, so navigating the app is reading the constellation.
struct OrionField: View {
  /// nil shows the entire figure, centred. Onboarding uses that.
  var focus: OrionStation?
  /// How many stars have been revealed. Used by onboarding to draw the figure.
  var reveal: Int = 9
  /// Draws a moving bead along the figure.
  var travelling: Bool = true
  var showsLabels: Bool = false

  @Environment(\.brand) private var brand
  @Environment(MotionSource.self) private var motion
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let projection = SkyProjection()

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      // With a station, the camera centres on its star and moves in. Without
      // one, the whole figure is centred and left at its natural size.
      let anchor = focus.map { projection.point(for: $0.anchor) }
      let scale = focus?.zoom ?? 1.0
      let target = CGPoint(
        x: anchor?.x ?? figureCentre.x,
        y: anchor?.y ?? figureCentre.y
      )
      let restY: CGFloat = focus == nil ? 0.5 : 0.66
      let drift = driftOffset

      ZStack {
        chart(in: size)
          .scaleEffect(scale)
          .offset(
            x: (0.5 - target.x) * size.width * scale + drift.width,
            y: (restY - target.y) * size.height * scale + drift.height
          )
      }
      .frame(width: size.width, height: size.height)
      .clipped()
    }
    .allowsHitTesting(false)
    .animation(.spring(response: 1.0, dampingFraction: 0.88), value: focus)
  }

  private var figureCentre: UnitPoint {
    let points = OrionConstellation.all.map { projection.point(for: $0) }
    guard !points.isEmpty else { return UnitPoint(x: 0.5, y: 0.5) }
    let x = points.reduce(0) { $0 + $1.x } / Double(points.count)
    let y = points.reduce(0) { $0 + $1.y } / Double(points.count)
    return UnitPoint(x: x, y: y)
  }

  private var driftOffset: CGSize {
    guard !reduceMotion, motion.isAvailable, motion.isEnabled else { return .zero }
    return CGSize(width: motion.tilt.width * 18, height: motion.tilt.height * 10)
  }

  // MARK: Chart

  private func chart(in size: CGSize) -> some View {
    let inset: CGFloat = 46
    let rect = CGRect(
      x: inset,
      y: size.height * 0.06,
      width: size.width - inset * 2,
      height: size.height * 0.56
    )

    return ZStack {
      segments(in: rect)
      if travelling && !reduceMotion { bead(in: rect) }
      stars(in: rect)
      if showsLabels { labels(in: rect) }
    }
  }

  /// The figure itself: one continuous hairline through the real positions.
  private func segments(in rect: CGRect) -> some View {
    Canvas { context, _ in
      for (a, b) in OrionConstellation.segments.prefix(max(0, reveal - 2)) {
        guard let from = OrionConstellation.star(a), let to = OrionConstellation.star(b) else { continue }
        let p1 = projection.point(for: from)
        let p2 = projection.point(for: to)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * p1.x, y: rect.minY + rect.height * p1.y))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * p2.x, y: rect.minY + rect.height * p2.y))
        context.stroke(
          path,
          // The belt is drawn slightly heavier: it is the part everyone knows.
          with: .color(brand.text.opacity(isBelt(a, b) ? 0.42 : 0.20)),
          style: StrokeStyle(lineWidth: isBelt(a, b) ? 1.1 : 0.8, lineCap: .round)
        )
      }
    }
    .animation(.easeOut(duration: 0.7), value: reveal)
  }

  private func isBelt(_ a: String, _ b: String) -> Bool {
    ["mintaka", "alnilam", "alnitak"].contains(a) && ["mintaka", "alnilam", "alnitak"].contains(b)
  }

  /// A small dot travelling the figure, forever. This is the app's constant
  /// motion: slow enough to ignore, alive enough that the screen is never dead.
  private func bead(in rect: CGRect) -> some View {
    TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let period: Double = 16
      let phase = (t.truncatingRemainder(dividingBy: period) / period)
      let points = orderedPathPoints(in: rect)
      let position = interpolated(points, at: phase)

      Circle()
        .fill(brand.text.opacity(0.75))
        .frame(width: 4, height: 4)
        .position(position)
    }
  }

  /// The figure walked as one stroke, so the bead reads as tracing the
  /// constellation rather than hopping between random stars.
  private func orderedPathPoints(in rect: CGRect) -> [CGPoint] {
    let order = [
      "betelgeuse", "bellatrix", "meissa",
      "betelgeuse", "alnitak", "alnilam", "mintaka",
      "bellatrix", "rigel", "mintaka", "hatysa", "alnitak", "saiph",
    ]
    return order.compactMap { id in
      guard let star = OrionConstellation.star(id) else { return nil }
      let p = projection.point(for: star)
      return CGPoint(x: rect.minX + rect.width * p.x, y: rect.minY + rect.height * p.y)
    }
  }

  private func interpolated(_ points: [CGPoint], at phase: Double) -> CGPoint {
    guard points.count > 1 else { return points.first ?? .zero }
    let scaled = phase * Double(points.count - 1)
    let index = min(Int(scaled), points.count - 2)
    let local = scaled - Double(index)
    let a = points[index]
    let b = points[index + 1]
    return CGPoint(
      x: a.x + (b.x - a.x) * local,
      y: a.y + (b.y - a.y) * local
    )
  }

  private func stars(in rect: CGRect) -> some View {
    ForEach(Array(OrionConstellation.all.enumerated()), id: \.element.id) { index, star in
      let p = projection.point(for: star)
      // Brighter stars are bigger, compressed so Betelgeuse does not swamp the
      // belt.
      let radius = 2.0 + max(0, 2.6 - star.magnitude) * 1.15
      let isStation = OrionStation.allCases.contains { $0.anchor.id == star.id }
      let isFocused = focus?.anchor.id == star.id
      let shown = index < reveal

      ZStack {
        Circle()
          .fill(brand.text)
          .frame(width: radius * 2, height: radius * 2)

        if isStation {
          // Stations get a ring, which is the only ornament on the chart and
          // therefore reads immediately as "this one is a place".
          Circle()
            .strokeBorder(brand.text.opacity(isFocused ? 0.55 : 0.22), lineWidth: isFocused ? 1.2 : 0.9)
            .frame(width: radius * 6.4, height: radius * 6.4)
        }
      }
      .position(x: rect.minX + rect.width * p.x, y: rect.minY + rect.height * p.y)
      .opacity(shown ? 1 : 0)
      .scaleEffect(shown ? 1 : 0.5)
      .animation(.spring(response: 0.7, dampingFraction: 0.75).delay(Double(index) * 0.04), value: reveal)
    }
  }

  private func labels(in rect: CGRect) -> some View {
    ForEach(OrionConstellation.all) { star in
      let p = projection.point(for: star)
      Text(star.name.uppercased())
        .font(.system(size: 7, weight: .medium))
        .tracking(1.6)
        .foregroundStyle(brand.textTertiary)
        .position(
          x: rect.minX + rect.width * p.x,
          y: rect.minY + rect.height * p.y + 16
        )
    }
  }
}
