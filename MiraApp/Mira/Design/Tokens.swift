import SwiftUI

// MARK: - Hex

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}

// MARK: - Current brand
//
// Two products ship from one set of screens. Rather than thread a theme through
// every view, the active brand is set once at launch and the token layer reads
// from it.
//
// This is deliberately a single global rather than injected state: the two
// brands are separate apps in separate processes, so there is never more than
// one theme alive at a time, and the alternative is a theme parameter on every
// view in the app for no benefit.

enum CurrentBrand {
  /// Set by each app entry point before any view renders.
  nonisolated(unsafe) static var theme: BrandTheme = .orion
}

// MARK: - Colour

/// The palette, read from the active brand.
///
/// Contrast is verified per brand, not assumed: Orion's silver measures 2.50:1
/// and is therefore material-only, while `ink` and the text ramp clear 4.5:1 in
/// both products.
enum MiraColor {
  private static var t: BrandTheme { CurrentBrand.theme }

  // Surfaces
  static var canvas: Color { t.canvas }
  static var surface: Color { t.surface }
  static var ink: Color { t.ink }
  static var inkRaised: Color { t.ink }
  static var inkElevated: Color { t.ink }
  static var hairline: Color { t.hairline }
  static var hairlineStrong: Color { t.hairline }

  // Text
  static var text: Color { t.text }
  static var textSecondary: Color { t.textSecondary }
  static var textTertiary: Color { t.textTertiary }

  // Accent
  static var accent: Color { t.accent }
  static var accentDeep: Color { t.accentDeep }
  static var accentTint: Color { t.accentTint }
  /// Text/fill colour that pairs with `accent` when used as a background.
  static var accentForeground: Color { t.accentForeground }
  static var gold: Color { t.accent }
  static var goldBright: Color { t.accent }
  static var goldRule: Color { t.accent.opacity(0.32) }

  // Legacy aliases kept so screens written against the earlier names keep
  // working while the brand layer settles.
  static var bone: Color { t.text }
  static var boneSecondary: Color { t.textSecondary }
  static var boneTertiary: Color { t.textTertiary }
  static var boneQuaternary: Color { t.textTertiary.opacity(0.7) }
  static var void: Color { t.ink }

  // Status, shared by both brands: a payment state means the same thing in
  // either product, so it is not themed.
  static let settled = Color(hex: 0x2F6B4F)
  static let pending = Color(hex: 0x8A5A12)
  static let failed = Color(hex: 0x9E2B2A)
  static let unknown = Color(hex: 0x5E6570)
  static let info = Color(hex: 0x4A6B82)
}

// MARK: - Status tone

enum StatusTone: Sendable {
  case neutral
  case progress
  case positive
  case negative
  case indeterminate

  var color: Color {
    switch self {
    case .neutral: return MiraColor.textTertiary
    case .progress: return MiraColor.pending
    case .positive: return MiraColor.settled
    case .negative: return MiraColor.failed
    case .indeterminate: return MiraColor.unknown
    }
  }

  var glyph: String {
    switch self {
    case .neutral: return "minus"
    case .progress: return "clock"
    case .positive: return "checkmark"
    case .negative: return "xmark"
    case .indeterminate: return "questionmark"
    }
  }
}

extension PaymentState {
  var tone: StatusTone {
    switch self {
    case .draft: return .neutral
    case .awaitingApproval, .submitting, .pending: return .progress
    case .settled: return .positive
    case .failed: return .negative
    case .statusUnknown: return .indeterminate
    }
  }

  var explanation: String {
    switch self {
    case .draft: return "Prepared. Nothing has been sent."
    case .awaitingApproval: return "Waiting for your approval."
    case .submitting: return "Handing this to the provider."
    case .pending: return "The provider has it and has not finished."
    case .settled: return "The provider reported this as settled."
    case .failed: return "The provider reported this as failed. No money moved."
    case .statusUnknown:
      return "No answer in time. Mira will check before anything else happens."
    }
  }
}

// MARK: - Spacing and shape

enum Space {
  static let xxs: CGFloat = 4
  static let xs: CGFloat = 8
  static let sm: CGFloat = 12
  static let md: CGFloat = 18
  static let lg: CGFloat = 26
  static let xl: CGFloat = 38
  static let xxl: CGFloat = 56
  static let xxxl: CGFloat = 84
  static let gutter: CGFloat = 24
}

enum Radius {
  static let small: CGFloat = 10
  static let medium: CGFloat = 16
  static let large: CGFloat = 22
  static let pill: CGFloat = 999
}
