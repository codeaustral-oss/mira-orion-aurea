import SwiftUI

// MARK: - Wordmark

/// Mira.
///
/// Set in the system face at tight tracking, with one deliberate departure: the
/// dot of the i is drawn rather than typeset, enlarged, and coloured gold. The
/// letterforms stay completely ordinary so that the single altered element is
/// what you remember.
///
/// The i is composed from a circle and a stem rather than overlaid on a glyph,
/// so the mark stays crisp at every size and cannot drift when font metrics
/// change.
struct MiraWordmark: View {
  var size: CGFloat = 34
  var color: Color? = nil
  var dotColor: Color? = nil

  @Environment(\.brand) private var brand

  private var ink: Color { color ?? brand.text }
  private var dot: Color { dotColor ?? brand.accent }
  /// Optical tracking. Slightly tighter as the mark grows.
  private var tracking: CGFloat { -size * 0.035 }

  private var font: Font { .system(size: size, weight: .medium) }

  /// Lowercase x-height in this face, as a fraction of point size.
  private let xHeight: CGFloat = 0.512
  /// How far the dot floats above the stem.
  private let dotGap: CGFloat = 0.052
  /// Deliberately larger than a typeset dot (about 0.12em), but not so large
  /// that it stops reading as the letter's dot.
  private let dotScale: CGFloat = 0.205
  /// Stem weight. Heavier than the face's own stroke so the drawn letter has
  /// the same optical weight as the typeset ones either side of it.
  private let stemScale: CGFloat = 0.105

  var body: some View {
    HStack(alignment: .lastTextBaseline, spacing: size * 0.012) {
      Text("M")
        .font(font)
        .tracking(tracking)
        .foregroundStyle(ink)

      iGlyph

      Text("ra")
        .font(font)
        .tracking(tracking)
        .foregroundStyle(ink)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Mira")
  }

  /// Bottom of the stem sits on the text baseline, so the default last-text
  /// baseline of this view (its bottom edge) aligns it without a custom guide.
  private var iGlyph: some View {
    VStack(spacing: size * dotGap) {
      Circle()
        .fill(dot)
        .frame(width: size * dotScale, height: size * dotScale)
      Capsule()
        .fill(ink)
        .frame(width: size * stemScale, height: size * xHeight)
    }
    .padding(.horizontal, size * 0.030)
  }
}

// MARK: - Lockup

/// The wordmark with an optional line under it, used only on onboarding.
struct MiraLockup: View {
  var size: CGFloat = 40
  var color: Color? = nil

  @Environment(\.brand) private var brand

  private var ink: Color { color ?? brand.text }
  var tagline: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      MiraWordmark(size: size, color: ink, dotColor: brand.accent)
      if let tagline {
        Text(tagline)
          .font(MiraFont.body(16))
          .foregroundStyle(ink.opacity(0.62))
      }
    }
  }
}
