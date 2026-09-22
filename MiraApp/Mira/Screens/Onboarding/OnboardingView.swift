import SwiftUI

/// Onboarding.
///
/// Four ideas, one per step, and the scene moves with you: the gold sphere
/// travels between positions in real depth rather than the pages sliding past
/// each other. Step 3 is the one piece of administration the product genuinely
/// needs, and it is asked as two plain questions with a reason attached.
struct OnboardingView: View {
  let onFinish: () -> Void

  @Environment(MiraSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var step = 0
  private let steps = 4

  var body: some View {
    ZStack {
      scene

      // A guarantee rather than a decoration: whatever the scene does, the
      // lower half resolves to canvas so the type always has contrast. The
      // previous pass let a light object sit under body copy and washed it out.
      LinearGradient(
        stops: [
          .init(color: MiraColor.canvas.opacity(0), location: 0.38),
          .init(color: MiraColor.canvas.opacity(0.92), location: 0.62),
          .init(color: MiraColor.canvas, location: 0.78),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      VStack(spacing: 0) {
        progress
          .padding(.horizontal, Space.gutter)
          .padding(.top, Space.sm)

        Spacer(minLength: Space.lg)

        // The body scrolls rather than clips, so an accessibility text size
        // rearranges the page instead of truncating it.
        ScrollView {
          content
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.md)
            .readableWidth()
        }
        .scrollBounceBehavior(.basedOnSize)

        Spacer(minLength: Space.md)

        footer
          .padding(.horizontal, Space.gutter)
          .readableWidth()
          .padding(.bottom, Space.md)
      }
    }
  }

  // MARK: Scene

  private var scene: some View {
    // The sphere and ring own the upper half; the lower half belongs to the
    // type. Keeping them apart is what stops the art from washing out the copy,
    // which was the failure in the first pass.
    let sphere: (center: UnitPoint, width: Double, depth: Double) = {
      switch step {
      case 0: return (UnitPoint(x: 0.70, y: 0.24), 0.40, 0.92)
      case 1: return (UnitPoint(x: 0.76, y: 0.19), 0.28, 0.74)
      case 2: return (UnitPoint(x: 0.22, y: 0.82), 0.22, 0.86)
      default: return (UnitPoint(x: 0.78, y: 0.62), 0.30, 0.95)
      }
    }()

    let ring: (center: UnitPoint, width: Double) = {
      switch step {
      case 0: return (UnitPoint(x: 0.20, y: 0.17), 0.22)
      case 1: return (UnitPoint(x: 0.17, y: 0.26), 0.17)
      case 2: return (UnitPoint(x: 0.84, y: 0.15), 0.20)
      default: return (UnitPoint(x: 0.17, y: 0.28), 0.15)
      }
    }()

    return DepthScene(
      objects: [
        DepthObject(
          imageName: Obj.ring,
          depth: 0.52,
          width: ring.width,
          center: ring.center,
          opacity: 0.95,
          spin: step.isMultiple(of: 2) ? -12 : 8
        ),
        DepthObject(
          imageName: Obj.sphere,
          depth: sphere.depth,
          width: sphere.width,
          center: sphere.center
        ),
        DepthObject(
          imageName: Obj.card,
          depth: 0.88,
          width: step == 3 ? 0.66 : 0.001,
          center: UnitPoint(x: 0.52, y: 0.30),
          opacity: step == 3 ? 1 : 0
        ),
      ],
      grid: true,
      gridDepth: 0.06,
      maxRotation: 8,
      parallax: 40
    ) {
      EmptyView()
    }
    // Re-staging the scene is a single animated change, so the objects travel
    // together instead of each one arriving on its own schedule.
    .animation(.spring(response: 0.85, dampingFraction: 0.82), value: step)
  }

  // MARK: Progress

  private var progress: some View {
    HStack(spacing: 7) {
      ForEach(0..<steps, id: \.self) { index in
        if index == step {
          // The current step is the brand dot itself.
          MiraDot(size: 9)
        } else {
          Circle()
            .fill(MiraColor.text.opacity(0.16))
            .frame(width: 7, height: 7)
        }
      }
      Spacer()
      Text("Step \(step + 1) of \(steps)")
        .font(MiraFont.caption(12))
        .foregroundStyle(MiraColor.textTertiary)
        .monospacedDigit()
    }
    .animation(.easeOut(duration: 0.25), value: step)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step + 1) of \(steps)")
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    switch step {
    case 0: welcome
    case 1: thePlan
    case 2: theFacts
    default: thePromise
    }
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      MiraWordmark(size: 44)

      Text("Earn in dollars.\nSpend in reais.")
        .font(MiraFont.display(40, weight: .semibold))
        .tracking(-1.4)
        .foregroundStyle(MiraColor.text)
        .fixedSize(horizontal: false, vertical: true)

      Text(
        "Mira turns international income into a plan you can follow, and a local payment into a number you can check."
      )
      .font(MiraFont.body(17))
      .foregroundStyle(MiraColor.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.trailing, Space.xl)
    }
  }

  private var thePlan: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("This is the whole idea")
        .font(MiraFont.display(28, weight: .semibold))
        .tracking(-0.9)
        .foregroundStyle(MiraColor.text)

      // The figure is the hero of the step, not a decoration on it.
      HeroNumber(session.clearedUSD.display, size: 52)

      Text(
        "One income, given four jobs. You can change any of them, and Mira will tell you when the numbers stop adding up."
      )
      .font(MiraFont.body(17))
      .foregroundStyle(MiraColor.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var theFacts: some View {
    VStack(alignment: .leading, spacing: Space.lg) {
      Text("Two things that are\nnot the same")
        .font(MiraFont.display(28, weight: .semibold))
        .tracking(-0.9)
        .foregroundStyle(MiraColor.text)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 0) {
        factRow(
          label: "I am legally resident in",
          selection: Binding(
            get: { session.context.legalResidence },
            set: {
              session.context.legalResidence = $0
              session.context.documentCountry = $0
            }
          )
        )
        Rule()
        factRow(
          label: "I am currently in",
          selection: Binding(
            get: { session.context.presentLocation },
            set: { session.context.presentLocation = $0 }
          )
        )
      }
      .background(
        MiraColor.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(MiraColor.hairline, lineWidth: 1)
      }

      Text(
        "Your residence decides what you can open. Where you are only changes what Mira suggests."
      )
      .font(MiraFont.body(15))
      .foregroundStyle(MiraColor.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var thePromise: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("You approve\nevery payment.")
        .font(MiraFont.display(32, weight: .semibold))
        .tracking(-1.1)
        .foregroundStyle(MiraColor.text)
        .fixedSize(horizontal: false, vertical: true)

      Text(
        "Mira prepares, explains and records. It cannot send anything, change a limit, or decide who is eligible. Those are yours."
      )
      .font(MiraFont.body(17))
      .foregroundStyle(MiraColor.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.trailing, Space.md)
    }
  }

  private func factRow(label: String, selection: Binding<Country>) -> some View {
    HStack(spacing: Space.sm) {
      CountryMark(country: selection.wrappedValue)
      Text(label)
        .font(MiraFont.body(16))
        .foregroundStyle(MiraColor.text)
      Spacer(minLength: Space.xs)
      Picker(label, selection: selection) {
        ForEach(Country.all) { country in
          Text(country.name).tag(country)
        }
      }
      .pickerStyle(.menu)
      .tint(MiraColor.text)
    }
    .padding(.horizontal, Space.md)
    .padding(.vertical, 6)
  }

  // MARK: Footer

  private var footer: some View {
    VStack(spacing: Space.sm) {
      HStack(spacing: Space.xs) {
        if step > 0 {
          Button("Back") {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { step -= 1 }
          }
          .buttonStyle(MiraButtonStyle(kind: .quiet, fullWidth: false))
        }
        Button(step == steps - 1 ? "Open Mira" : "Continue") {
          if step == steps - 1 {
            onFinish()
          } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { step += 1 }
          }
        }
        .buttonStyle(MiraButtonStyle(kind: .primary))
      }

    }
  }
}
