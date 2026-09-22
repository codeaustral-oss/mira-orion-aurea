import SwiftUI
import UIKit

// MARK: - Brand
//
// Two products from one core. They share every rule about money and nothing
// about how they look.
//
// The themes are values rather than static globals, and reach the screens
// through the environment, so the same view code renders as either product
// without a single `if brand ==` inside a screen.

enum BrandKind: String, CaseIterable, Sendable {
  case orion
  case aurea

  var theme: BrandTheme { self == .orion ? .orion : .aurea }
}

struct BrandTheme: Sendable {
  let kind: BrandKind

  // MARK: Identity
  /// "Mira Orion"
  let productName: String
  /// "Go Beyond."
  let tagline: String
  /// The three-word column that runs down the right of a headline.
  let kicker: [String]
  /// The line that closes a screen.
  let closing: String

  // MARK: Surfaces
  let canvas: Color
  let surface: Color
  let ink: Color
  let hairline: Color

  // MARK: Text
  /// Primary text. Verified at 16:1 or better on canvas.
  let text: Color
  let textSecondary: Color
  let textTertiary: Color

  // MARK: Accent
  /// The accent used for material, fills and the avatar.
  let accent: Color
  /// The accent at a weight that can carry meaning at small sizes. Orion's
  /// silver is 2.5:1, which is a material, not a signal, so anything that has
  /// to be read uses this deeper value instead.
  let accentDeep: Color
  let accentTint: Color
  /// The colour that sits on top of `accent` when it is used as a fill. Aurea's
  /// burgundy is dark, so it takes white; Orion's silver is light, so it takes
  /// ink. Declared here so a gold button can never end up dark-on-dark.
  let accentForeground: Color

  // MARK: Type
  /// Aurea sets its display voice in a serif; Orion stays in the system sans.
  let serifDisplay: Bool

  /// Display face for headlines and hero figures. Scales with Dynamic Type.
  func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    let scaled = MiraFont.scalableSize(size, textStyle: .title1)
    return serifDisplay
      ? .system(size: scaled, weight: weight, design: .serif)
      : .system(size: scaled, weight: weight)
  }

  /// The numeral face. Always tabular. Scales with Dynamic Type.
  func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: MiraFont.scalableSize(size, textStyle: .largeTitle), weight: weight)
      .monospacedDigit()
  }

  /// Tracking for display type.
  ///
  /// A serif is not a grotesk with serifs: pulled tight it goes cramped and
  /// shouty. Aurea opens slightly instead, which is what makes it read as quiet
  /// rather than as a headline. Orion, in the system sans, closes slightly.
  func displayTracking(_ size: CGFloat) -> CGFloat {
    serifDisplay ? size * 0.004 : -size * 0.032
  }

  // MARK: Navigation
  let tabs: [TabSpec]

  struct TabSpec: Sendable, Hashable {
    let key: String
    let title: String
    let glyph: String
  }

  // MARK: Onboarding copy
  let onboardingHeadline: String
  let onboardingSubhead: String
  let onboardingCTA: String

  // MARK: The avatar
  let avatar: AvatarStyle

  enum AvatarStyle: String, Sendable {
    /// A rendered sphere with an orbiting body. Dimensional.
    case orbit
    /// A drawn ellipse with a travelling dot. Engraved.
    case engraved
  }
}

// MARK: - Orion

extension BrandTheme {
  /// Black, white and a touch of silver.
  ///
  /// The silver measures 2.50:1 on the canvas. That is deliberate and it is why
  /// there are two of them: `accent` is the metal, used for fills, hairlines and
  /// the avatar where nothing has to be read, and `accentDeep` is what carries
  /// meaning at 4.72:1.
  static let orion = BrandTheme(
    kind: .orion,
    productName: "Mira Orion",
    tagline: "Go Beyond.",
    kicker: ["People", "Places", "Possibilities"],
    closing: "A Brighter Financial Horizon",
    canvas: Color(hex: 0xFAFAFA),
    surface: Color(hex: 0xFFFFFF),
    ink: Color(hex: 0x0D0D0F),
    hairline: Color(hex: 0xE2E4E7),
    text: Color(hex: 0x0B0B0D),
    textSecondary: Color(hex: 0x54575C),
    textTertiary: Color(hex: 0x6F7379),
    accent: Color(hex: 0x9BA1A8),
    accentDeep: Color(hex: 0x6B7178),
    accentTint: Color(hex: 0xEFF1F3),
    accentForeground: Color(hex: 0x0B0B0D),
    serifDisplay: false,
    tabs: [
      TabSpec(key: "accounts", title: "Accounts", glyph: "circle.lefthalf.filled"),
      TabSpec(key: "move", title: "Move", glyph: "arrow.left.arrow.right"),
      // Mira is a destination, not a floating button. The glyph is a dotted
      // circle because the assistant is the dot, at every scale.
      TabSpec(key: "mira", title: "Mira", glyph: "circle.dotted"),
      TabSpec(key: "you", title: "You", glyph: "person"),
    ],
    onboardingHeadline: "Global money\nfor a freer you.",
    onboardingSubhead: "Earn in USD. Spend locally.\nMove with confidence.",
    onboardingCTA: "Get started",
    avatar: .orbit
  )

  /// Classical and unhurried, and almost white. The ground is a neutral
  /// near-white, not a warm paper: the burgundy accents and the luminous oil
  /// portraits supply all of the warmth, and the canvas stays out of their way.
  /// Every text token still clears 4.5:1 against it.
  static let aurea = BrandTheme(
    kind: .aurea,
    productName: "Mira Aurea",
    tagline: "Looking After You.",
    kicker: ["People", "Places", "Progress"],
    closing: "A Calmer Financial Tomorrow",
    canvas: Color(hex: 0xFCFCFC),      // 18.4:1 under the text colour
    surface: Color(hex: 0xFFFFFF),
    ink: Color(hex: 0x1A1114),
    hairline: Color(hex: 0xE8E8E8),
    text: Color(hex: 0x1A1114),        // 17.76:1
    textSecondary: Color(hex: 0x584A4D),  // 8.05:1
    textTertiary: Color(hex: 0x7A6C6F),   // 4.79:1
    accent: Color(hex: 0x5C1A24),
    accentDeep: Color(hex: 0x5C1A24),
    accentTint: Color(hex: 0xF2E4E2),
    accentForeground: Color(hex: 0xFFFFFF),
    serifDisplay: true,
    tabs: [
      TabSpec(key: "accounts", title: "Accounts", glyph: "building.columns"),
      TabSpec(key: "move", title: "Move Money", glyph: "paperplane"),
      TabSpec(key: "mira", title: "Mira", glyph: "circle.dotted"),
      // The card lives on Accounts and in Profile, so a separate Card tab would
      // be a third door to the same room.
      TabSpec(key: "you", title: "Profile", glyph: "person"),
    ],
    onboardingHeadline: "Money\nwith more care.",
    onboardingSubhead: "Earn in USD. Spend locally.\nPlan with calm.",
    onboardingCTA: "Get started",
    avatar: .engraved
  )
}

// MARK: - Environment

private struct BrandKey: EnvironmentKey {
  static let defaultValue = BrandTheme.orion
}

extension EnvironmentValues {
  var brand: BrandTheme {
    get { self[BrandKey.self] }
    set { self[BrandKey.self] = newValue }
  }
}

extension View {
  func brand(_ theme: BrandTheme) -> some View {
    environment(\.brand, theme)
  }
}
