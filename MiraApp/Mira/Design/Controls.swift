import SwiftUI

// MARK: - Surfaces
//
// The app is mostly plain canvas. A `Panel` exists for the few places that need
// to lift off it, and there are never panels inside panels.

struct Panel<Content: View>: View {
  var padding: CGFloat = Space.md
  var tint: Color? = nil
  @ViewBuilder var content: () -> Content

  init(
    padding: CGFloat = Space.md, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content
  ) {
    self.padding = padding
    self.tint = tint
    self.content = content
  }

  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        tint ?? MiraColor.surface,
        in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(MiraColor.hairline, lineWidth: 1)
      }
  }
}

/// A hairline rule. On white it is grey; on black it is a whisper.
struct Rule: View {
  var onInk: Bool = false
  /// An accent-tinted rule, for separating the two figures of a transaction.
  var accented: Bool = false

  @Environment(\.brand) private var brand

  var body: some View {
    Rectangle()
      .fill(
        accented
          ? brand.accent.opacity(0.45) : (onInk ? brand.hairline.opacity(0.4) : brand.hairline)
      )
      .frame(height: 1)
  }
}

// MARK: - Buttons
//
// One button, not two. The older `MiraButtonStyle` and `BrandButtonStyle` grew
// apart — different fonts, different padding, and a gold variant that set dark
// ink on Aurea's dark burgundy. This is the single implementation; the second
// name is kept as a typealias so no screen had to change.

/// The one button in the app, coloured by whichever brand is in the
/// environment. Every label is the system face at a size that scales with
/// Dynamic Type: a button is a control, not a display voice.
struct MiraButtonStyle: ButtonStyle {
  enum Kind {
    /// The single most important action on a screen.
    case primary
    /// A real alternative, not a consolation prize.
    case secondary
    /// The accent-filled commitment. Uses `accentForeground` so the label is
    /// always readable on the accent, in either brand.
    case gold
    /// Inline, low-emphasis actions.
    case quiet
    case destructive

    /// The same thing, named for what it is.
    static var accent: Kind { .gold }
  }

  var kind: Kind = .primary
  var fullWidth: Bool = true

  @Environment(\.brand) private var brand

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(MiraFont.label(16))
      .foregroundStyle(foreground)
      .padding(.vertical, 15)
      .padding(.horizontal, Space.lg)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(background)
      .overlay {
        if kind == .secondary {
          Capsule().strokeBorder(brand.hairline, lineWidth: 1)
        }
      }
      .clipShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.92 : 1)
      // A short, firm ease. No bounce: this is a bank, not a game.
      .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
  }

  private var foreground: Color {
    switch kind {
    case .primary: return brand.canvas
    case .gold: return brand.accentForeground
    case .secondary, .quiet: return brand.text
    case .destructive: return MiraColor.failed
    }
  }

  @ViewBuilder
  private var background: some View {
    switch kind {
    case .primary: brand.ink
    case .gold: brand.accent
    case .secondary: brand.surface
    case .quiet: Color.clear
    case .destructive: MiraColor.failed.opacity(0.10)
    }
  }
}

// MARK: - Selection row

/// A tappable row. The chevron is the only ornament, and the tap target is the
/// whole row rather than just the text.
struct TapRow<Content: View>: View {
  var tint: Color? = nil
  var action: () -> Void
  @ViewBuilder var content: () -> Content

  init(
    tint: Color? = nil, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content
  ) {
    self.tint = tint
    self.action = action
    self.content = content
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: Space.sm) {
        content()
        Spacer(minLength: Space.xs)
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MiraColor.textTertiary)
      }
      .padding(.vertical, 15)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(tint ?? .clear)
  }
}

// MARK: - Brand button

/// The chat screens were written against this name before the two button
/// styles were merged. It is the same control.
typealias BrandButtonStyle = MiraButtonStyle
