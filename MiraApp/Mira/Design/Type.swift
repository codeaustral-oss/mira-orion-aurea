import SwiftUI
import UIKit

// MARK: - Type
//
// One family, SF Pro, worked with weight and scale contrast rather than a second
// typeface. It is the native face, it renders tabular figures correctly, and it
// keeps the app feeling like an operating system rather than a brochure.
//
// The brand display face — Aurea's serif — is reserved for screen and sheet
// titles and the one hero figure. Card headings, field labels, buttons, status
// words and every other piece of running UI are the system sans, so a card does
// not read as a headline and a control does not read as a display voice.
//
// Every size here is a design size at the default Dynamic Type setting. SF Pro
// is a system face, so it does not grow on its own: `scalableSize` runs each
// size through the metrics of a matching text style, so the type grows and
// shrinks with the user's accessibility setting like any other content.

enum MiraFont {
  private static var t: BrandTheme { CurrentBrand.theme }

  /// Scale a design size with the user's Dynamic Type setting. At the default
  /// setting this returns the size unchanged, so existing layouts are untouched.
  static func scalableSize(_ size: CGFloat, textStyle: UIFont.TextStyle = .body) -> CGFloat {
    UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size)
  }

  /// The one number. Tabular in both brands, because a figure that jitters is a
  /// figure you cannot trust, and Orion sets it in the sans while Aurea sets it
  /// in the serif to match its display voice.
  static func hero(_ size: CGFloat) -> Font {
    t.figure(size, weight: .semibold)
  }

  /// Large supporting figures.
  static func figure(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
    t.figure(size, weight: weight)
  }

  /// Screen titles and section heads.
  static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    t.display(size, weight: weight)
  }

  static func title(_ size: CGFloat = 20) -> Font {
    .system(size: scalableSize(size, textStyle: .title3), weight: .semibold)
  }

  static func body(_ size: CGFloat = 16) -> Font {
    .system(size: scalableSize(size), weight: .regular)
  }

  static func label(_ size: CGFloat = 14) -> Font {
    .system(size: scalableSize(size, textStyle: .subheadline), weight: .medium)
  }

  static func caption(_ size: CGFloat = 12) -> Font {
    .system(size: scalableSize(size, textStyle: .caption1), weight: .regular)
  }

  /// References, keys and identifiers only.
  static func mono(_ size: CGFloat = 13) -> Font {
    .system(size: scalableSize(size, textStyle: .footnote), weight: .regular, design: .monospaced)
  }
}

// MARK: - The one number

/// A screen's single answer.
///
/// Size is chosen so the figure is readable at arm's length, which is the whole
/// premise of the interface. `minimumScaleFactor` lets Dynamic Type grow without
/// ever truncating a digit: a clipped number is worse than a smaller one.
struct HeroNumber: View {
  let value: String
  var size: CGFloat = 68
  var color: Color = MiraColor.text
  var alignment: HorizontalAlignment = .leading

  init(
    _ value: String, size: CGFloat = 68, color: Color = MiraColor.text,
    alignment: HorizontalAlignment = .leading
  ) {
    self.value = value
    self.size = size
    self.color = color
    self.alignment = alignment
  }

  var body: some View {
    Text(value)
      .font(MiraFont.hero(size))
      .tracking(-size * 0.032)
      .foregroundStyle(color)
      .lineLimit(1)
      .minimumScaleFactor(0.45)
      .contentTransition(.numericText())
      .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The caption that sits under a hero figure and says what it is. Deliberately
/// plain: no unit abbreviation, no currency symbol ambiguity.
struct FigureCaption: View {
  let text: String
  var color: Color = MiraColor.textSecondary

  init(_ text: String, color: Color = MiraColor.textSecondary) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(MiraFont.body(16))
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Small pieces

/// A label and its value on one line. The only repeated data pattern in the app,
/// and it is used sparingly: if a screen has more than four of these, the screen
/// is doing too much.
struct FieldLine: View {
  let label: String
  let value: String
  var mono: Bool = false
  var strong: Bool = false
  var valueColor: Color? = nil

  init(
    label: String, value: String, mono: Bool = false, strong: Bool = false, valueColor: Color? = nil
  ) {
    self.label = label
    self.value = value
    self.mono = mono
    self.strong = strong
    self.valueColor = valueColor
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      Text(label)
        .font(MiraFont.body(15))
        .foregroundStyle(MiraColor.textSecondary)
      Spacer(minLength: Space.xs)
      Text(value)
        .font(
          mono
            ? MiraFont.mono(14)
            : MiraFont.figure(strong ? 17 : 16, weight: strong ? .semibold : .medium)
        )
        .foregroundStyle(valueColor ?? MiraColor.text)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A single line of plain-language explanation. Used for the few things that
/// genuinely must be said: simulated money, an uninsured reserve, an unknown
/// payment. Stated once, at reading size, not as fine print.
struct Note: View {
  let text: String
  var tone: StatusTone = .neutral

  init(_ text: String, tone: StatusTone = .neutral) {
    self.text = text
    self.tone = tone
  }

  var body: some View {
    HStack(alignment: .top, spacing: Space.xs) {
      Circle()
        .fill(tone.color)
        .frame(width: 6, height: 6)
        .padding(.top, 7)
      Text(text)
        .font(MiraFont.body(14))
        .foregroundStyle(MiraColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}

/// A status pill: glyph, word and tone together, so nothing depends on colour.
struct StatusPill: View {  let glyph: String
  let text: String
  let tone: StatusTone

  init(glyph: String, text: String, tone: StatusTone) {
    self.glyph = glyph
    self.text = text
    self.tone = tone
  }

  init(state: PaymentState) {
    self.glyph = state.tone.glyph
    self.text = state.label
    self.tone = state.tone
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: glyph)
        .font(.system(size: 10, weight: .bold))
      Text(text)
        .font(MiraFont.label(13))
    }
    .foregroundStyle(tone.color)
    .padding(.horizontal, 11)
    .padding(.vertical, 5)
    .background(tone.color.opacity(0.10), in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(text)")
  }
}

// MARK: - Screen title

/// The brand's screen-title face and tracking, applied in one place.
///
/// Utility headers used to carry their own negative tracking values, so the same
/// title looked different on different sheets. This is the only way a screen
/// title is set.
extension View {
  func screenTitle(_ size: CGFloat = 26, weight: Font.Weight = .semibold) -> some View {
    modifier(ScreenTitleModifier(size: size, weight: weight))
  }
}

private struct ScreenTitleModifier: ViewModifier {
  let size: CGFloat
  let weight: Font.Weight

  @Environment(\.brand) private var brand

  func body(content: Content) -> some View {
    content
      .font(brand.display(size, weight: weight))
      .tracking(brand.displayTracking(size))
  }
}
