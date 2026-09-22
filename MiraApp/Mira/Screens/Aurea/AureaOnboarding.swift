import SwiftUI

// MARK: - Aurea onboarding
//
// Four ideas, one per step, over a single painting that fills the screen. The
// picture is the product's world — a lakeside settlement, or a garden terrace
// above the bay — and advancing does not change the page: the camera moves
// inside the painting, a few percent, so the place stays one place.
//
// The copy sits on the art. A scrim rising from the bottom keeps white type at
// reading contrast without flattening the picture, and the ledger feed sits low
// and centred between the two: a thin, living record of the sort of thing Mira
// keeps track of.
//
// The words are about the team, not about a bank: Mira coordinates six
// specialists who research, compare, organise and prepare, and the user reviews
// and approves whatever happens next.
struct AureaOnboarding: View {
  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @Environment(MiraSession.self) private var session

  @AppStorage("mira.onboarding.scene") private var sceneRaw = OnboardingScene.fallback.rawValue
  /// A launch-argument preview of a scene. It shadows the stored choice for
  /// this session only, so previewing never overwrites a real preference.
  @State private var sceneOverride: OnboardingScene?
  @State private var step: Int

  private let onFinish: () -> Void
  private let steps = 4

  /// `onFinish` is last so the product call site can use a trailing closure, and
  /// both debug parameters default, so a normal launch has nothing to pass.
  init(
    initialStep: Int? = nil,
    sceneOverride: OnboardingScene? = nil,
    onFinish: @escaping () -> Void
  ) {
    self.onFinish = onFinish
    _sceneOverride = State(initialValue: sceneOverride)
    _step = State(initialValue: min(max(initialStep ?? 0, 0), 3))
  }

  private var scene: OnboardingScene {
    sceneOverride ?? OnboardingScene(rawValue: sceneRaw) ?? .fallback
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let insets = proxy.safeAreaInsets
      // The words and the register are laid out in the safe area, so the footer
      // always clears the home indicator. The painting is laid out across the
      // whole screen and sits behind both: it overflows a frame that never grows
      // to contain it, which is what keeps it full-bleed.
      let screen = CGSize(
        width: size.width + insets.leading + insets.trailing,
        height: size.height + insets.top + insets.bottom
      )
      let canvas = size

      ZStack {
        // Holds the stack's own layout at the safe area, whatever the painting
        // behind it measures.
        Color.clear

        AureaBackdrop(scene: scene, step: step, reduceMotion: reduceMotion)

        // Notes spawning across the water, above the copy.
        LakeNotes(step: step, canvas: canvas)

        scrim

        VStack(alignment: .leading, spacing: 0) {
          topBar
          Spacer(minLength: 0)
          copy
          footer
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth(620)
      }
      .frame(width: size.width, height: size.height)
    }
    .background(brand.ink.ignoresSafeArea())
  }

  // MARK: - Atmosphere

  /// Heavier at the bottom where the type and the buttons live, clear at the
  /// top where the painting keeps its sky — but never so light that white type
  /// would have to fight the picture behind it.
  private var scrim: some View {
    ZStack {
      LinearGradient(
        stops: [
          .init(color: Color(hex: 0x0E0B10).opacity(0.34), location: 0.00),
          .init(color: Color(hex: 0x0E0B10).opacity(0.10), location: 0.16),
          .init(color: Color(hex: 0x0E0B10).opacity(0.28), location: 0.42),
          .init(color: Color(hex: 0x0E0B10).opacity(0.66), location: 0.58),
          .init(color: Color(hex: 0x0E0B10).opacity(0.88), location: 0.74),
          .init(color: Color(hex: 0x0E0B10).opacity(0.97), location: 0.88),
          .init(color: Color(hex: 0x0E0B10), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
      )

      // A vignette, to hold the eye in the middle of the painting.
      RadialGradient(
        colors: [.clear, Color(hex: 0x0B080D).opacity(0.34)],
        center: UnitPoint(x: 0.5, y: 0.40),
        startRadius: 120,
        endRadius: 620
      )
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(alignment: .center, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        MiraWordmark(size: 24, color: .white, dotColor: Color(hex: 0xE5C987))
        Text("LOOKING AFTER YOU.")
          .font(.system(size: 9, weight: .medium))
          .tracking(2.6)
          .foregroundStyle(.white.opacity(0.76))
      }
      Spacer(minLength: Space.sm)
      sceneSwitch
    }
    .padding(.top, Space.lg)
    .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
  }

  /// Both scenes, named, so the choice is made by looking rather than by
  /// guessing what a swap glyph would do. Styled for a picture ground.
  private var sceneSwitch: some View {
    HStack(spacing: 2) {
      ForEach(OnboardingScene.allCases) { option in
        Button {
          select(option)
        } label: {
          Text(option.title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(option == scene ? Color(hex: 0x1A1114) : .white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
              if option == scene { Capsule().fill(.white) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) scene")
        .accessibilityAddTraits(option == scene ? .isSelected : [])
      }
    }
    .padding(3)
    .background(.black.opacity(0.30), in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
  }

  private func select(_ option: OnboardingScene) {
    guard option != scene else { return }
    withAnimation(.easeInOut(duration: 0.4)) {
      if sceneOverride != nil {
        sceneOverride = option
      } else {
        sceneRaw = option.rawValue
      }
    }
  }

  // MARK: - Copy

  private var copy: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(headline)
        .font(.system(size: 30, weight: .regular, design: .serif))
        .tracking(0.2)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.4), radius: 14, y: 2)
        .id(step)
        .transition(.opacity.combined(with: .offset(y: 8)))

      Text(supporting)
        .font(.system(size: 14, weight: .regular, design: .serif))
        .foregroundStyle(.white.opacity(0.84))
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 1)

      stepDots
    }
    .animation(.easeOut(duration: 0.35), value: step)
    .padding(.bottom, Space.md)
  }

  private var headline: String {
    switch step {
    case 0: return "Mira and six\nspecialists."
    case 1: return "Research,\ncompare, decide."
    case 2: return "Organised in\none place."
    default: return "You review.\nYou approve."
    }
  }

  private var supporting: String {
    switch step {
    case 0:
      return "One assistant for your money and your plans."
    case 1:
      return "Options gathered, checked and compared, with the sources shown."
    case 2:
      return "Plans, budgets, cards and reminders, arranged in one place."
    default:
      return "Mira prepares and explains. Nothing moves until you say so."
    }
  }

  /// Four dots: where you are in the story, and how much of it is left. Drawn
  /// as dots rather than a bar because the brand's whole vocabulary is one dot.
  private var stepDots: some View {
    HStack(spacing: 7) {
      ForEach(0..<steps, id: \.self) { index in
        Circle()
          .fill(index == step ? Color(hex: 0xE5C987) : Color.white.opacity(index < step ? 0.55 : 0.28))
          .frame(width: index == step ? 8 : 6, height: index == step ? 8 : 6)
      }
    }
    .padding(.top, Space.xxs)
    .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step + 1) of \(steps)")
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: Space.xs) {
        if step > 0 {
          Button("Back") { goBack() }
            .buttonStyle(AureaGhostButtonStyle())
            .frame(width: 84)
        }
        Button(step == steps - 1 ? "Get started" : "Continue") {
          if step == steps - 1 {
            onFinish()
          } else {
            goForward()
          }
        }
        .buttonStyle(AureaLightButtonStyle())
      }

    }
    .frame(width: min(320, .infinity))
    .padding(.bottom, Space.lg)
    .accessibilityElement(children: .contain)
  }

  private func goForward() {
    withAnimation(.spring(response: 0.9, dampingFraction: 0.9)) {
      step = min(step + 1, steps - 1)
    }
  }

  private func goBack() {
    withAnimation(.spring(response: 0.9, dampingFraction: 0.9)) {
      step = max(step - 1, 0)
    }
  }
}

// MARK: - Buttons for a picture ground

/// Solid white pill, dark label. The one action on the screen.
struct AureaLightButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .regular, design: .serif))
      .foregroundStyle(Color(hex: 0x1A1114))
      .padding(.vertical, 13)
      .frame(maxWidth: .infinity)
      .background(.white, in: Capsule())
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
  }
}

/// A white hairline pill, for the secondary action.
struct AureaGhostButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .regular, design: .serif))
      .foregroundStyle(.white)
      .padding(.vertical, 13)
      // No maxWidth: the caller sets the width, so this cannot spill over the
      // primary action beside it.
      .padding(.horizontal, Space.md)
      .overlay { Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1) }
      .opacity(configuration.isPressed ? 0.8 : 1)
      .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
  }
}
