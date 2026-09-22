import SwiftUI

// MARK: - Mira, as a living dot
//
// One idea, implemented twice, because the two products are different objects.
//
//   · **Orion** is dimensional. A rendered body with an orbiting companion: the
//     assistant as a thing that goes out and comes back. Lit like a rendered
//     material, and it leans with the phone.
//   · **Aurea** is engraved. A drawn ellipse and a steady bead, the way a
//     celestial diagram is engraved on a plate: hairlines, no gradients, no
//     gloss. The assistant as something that is simply always there.
//
// Both are code, not images, so they stay crisp at any size and cost nothing to
// ship. Both stop moving under Reduce Motion.

// MARK: - Orion

/// A body with an orbiting companion.
struct OrbitalAvatar: View {
  var size: CGFloat = 120
  /// How fast the companion completes an orbit, in seconds.
  var period: Double = 7
  var showsBody: Bool = true

  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(MotionSource.self) private var motion

  private var bodyRadius: CGFloat { size * 0.29 }
  private var orbitA: CGFloat { size * 0.46 }
  private var orbitB: CGFloat { size * 0.17 }
  private var bead: CGFloat { max(3, size * 0.075) }

  var body: some View {
    TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 1.0 / 30.0)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      // A fixed angle under Reduce Motion: the composition still reads, it just
      // stops travelling.
      let phase =
        reduceMotion ? 0.9 : (t.truncatingRemainder(dividingBy: period) / period) * 2 * .pi
      let lean = reduceMotion || !motion.isAvailable ? .zero : motion.tilt

      ZStack {
        if showsBody {
          body3D
        }
        orbitRing
        companion(at: phase, lean: lean)
      }
      .frame(width: size, height: size)
      .rotation3DEffect(
        .degrees(lean.width * 10),
        axis: (x: 0, y: 1, z: 0),
        perspective: 0.6
      )
      .rotation3DEffect(
        .degrees(-lean.height * 8),
        axis: (x: 1, y: 0, z: 0),
        perspective: 0.6
      )
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Mira")
  }

  /// The body: a sphere lit from the upper left, with a rim of light on the
  /// lower right so it reads as a solid rather than a flat disc.
  private var body3D: some View {
    Circle()
      .fill(
        RadialGradient(
          stops: [
            .init(color: Color.white, location: 0.0),
            .init(color: brand.accentTint, location: 0.32),
            .init(color: brand.accent, location: 0.72),
            .init(color: brand.accentDeep, location: 1.0),
          ],
          center: UnitPoint(x: 0.34, y: 0.28),
          startRadius: 0,
          endRadius: bodyRadius * 1.9
        )
      )
      .frame(width: bodyRadius * 2, height: bodyRadius * 2)
      .overlay {
        // Specular highlight.
        Circle()
          .fill(
            RadialGradient(
              colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
              center: UnitPoint(x: 0.32, y: 0.26),
              startRadius: 0,
              endRadius: bodyRadius * 0.9
            )
          )
          .frame(width: bodyRadius * 2, height: bodyRadius * 2)
      }
      .shadow(color: brand.ink.opacity(0.18), radius: size * 0.06, y: size * 0.03)
  }

  private var orbitRing: some View {
    Ellipse()
      .stroke(
        LinearGradient(
          colors: [
            brand.accent.opacity(0.0), brand.accentDeep.opacity(0.75), brand.accent.opacity(0.0),
          ],
          startPoint: .leading,
          endPoint: .trailing
        ),
        lineWidth: max(1, size * 0.008)
      )
      .frame(width: orbitA * 2, height: orbitB * 2)
  }

  /// The bead rides a true ellipse. Trignometry rather than a squashed rotating
  /// container, so the bead stays perfectly round as it travels.
  private func companion(at phase: Double, lean: CGSize) -> some View {
    let x = orbitA * CGFloat(cos(phase))
    let y = orbitB * CGFloat(sin(phase))
    // In front of the body on the near half of the orbit, behind it on the far
    // half. This is the detail that makes it read as an orbit and not a decal.
    let isNear = sin(phase) > 0

    return Circle()
      .fill(isNear ? brand.ink : brand.accentDeep)
      .frame(width: bead, height: bead)
      .overlay {
        if isNear {
          Circle().strokeBorder(brand.surface.opacity(0.5), lineWidth: max(0.6, size * 0.005))
        }
      }
      .shadow(color: brand.ink.opacity(isNear ? 0.22 : 0), radius: size * 0.02, y: size * 0.008)
      .offset(x: x + lean.width * size * 0.02, y: y + lean.height * size * 0.012)
      .zIndex(isNear ? 2 : 0)
  }
}

// MARK: - Aurea

/// A drawn orbit and a steady bead, in the manner of an engraved plate.
struct EngravedAvatar: View {
  var size: CGFloat = 120
  var showsRings: Bool = true

  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var breathe = false

  private var orbitA: CGFloat { size * 0.46 }
  private var orbitB: CGFloat { size * 0.20 }
  private var bead: CGFloat { max(4, size * 0.085) }

  /// The bead sits fixed on the orbit and breathes rather than travelling. A
  /// plate does not animate; it is simply there.
  private var beadAngle: Double { -0.62 }

  var body: some View {
    ZStack {
      if showsRings {
        // Concentric hairlines, like the rings of an armillary.
        ForEach([0.92, 0.68, 0.42], id: \.self) { scale in
          Circle()
            .strokeBorder(brand.accent.opacity(0.18), lineWidth: max(0.6, size * 0.005))
            .frame(width: size * scale, height: size * scale)
        }
      }

      // The orbit: drawn, with a gap where the bead sits so the line appears to
      // pass behind it.
      Ellipse()
        .stroke(
          brand.accent.opacity(0.5),
          style: StrokeStyle(lineWidth: max(0.8, size * 0.006), lineCap: .round)
        )
        .frame(width: orbitA * 2, height: orbitB * 2)
        .rotationEffect(.degrees(-16))

      // A fine radial spoke, the way a diagram marks a position.
      Capsule()
        .fill(brand.accent.opacity(0.28))
        .frame(width: max(0.8, size * 0.006), height: size * 0.20)
        .offset(y: -size * 0.24)
        .rotationEffect(.degrees(-16))

      beadDot
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Mira")
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
        breathe = true
      }
    }
  }

  private var beadDot: some View {
    let x = orbitA * CGFloat(cos(beadAngle))
    let y = orbitB * CGFloat(sin(beadAngle))

    return ZStack {
      // A soft halo, so the bead reads as lit rather than pasted.
      Circle()
        .fill(brand.accent.opacity(0.14))
        .frame(width: bead * 3.1, height: bead * 3.1)
        .scaleEffect(breathe ? 1.14 : 0.9)
      Circle()
        .fill(brand.accent)
        .frame(width: bead, height: bead)
        .scaleEffect(breathe ? 1.0 : 0.92)
    }
    // Rotated with the orbit so the bead sits on the drawn line rather than
    // beside it.
    .rotationEffect(.degrees(-16))
    .offset(x: x, y: y)
  }
}

// MARK: - Facade

/// The brand's avatar, whichever it is.
///
/// Screens never ask which one; they ask for "Mira at this size".
struct MiraAvatar: View {
  var size: CGFloat = 120
  var showsBody: Bool = true

  @Environment(\.brand) private var brand

  var body: some View {
    switch brand.avatar {
    case .orbit:
      OrbitalAvatar(size: size, showsBody: showsBody)
    case .engraved:
      EngravedAvatar(size: size, showsRings: showsBody)
    }
  }
}

/// The avatar reduced to a dot, for headers and inline use.
struct MiraDot: View {
  var size: CGFloat = 10
  var color: Color? = nil
  var pulsing: Bool = false

  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var beat = false

  var body: some View {
    Circle()
      .fill(color ?? brand.accentDeep)
      .frame(width: size, height: size)
      .scaleEffect(pulsing && !reduceMotion ? (beat ? 1.18 : 0.82) : 1)
      .opacity(pulsing && !reduceMotion ? (beat ? 1 : 0.55) : 1)
      .animation(
        pulsing && !reduceMotion
          ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
          : .default,
        value: beat
      )
      .onAppear { beat = pulsing && !reduceMotion }
      .accessibilityHidden(true)
  }
}
