import SwiftUI

// MARK: - Orion onboarding
//
// Four steps on a star chart. The starfield, the engraved plate and the
// measuring arc still drift behind the page and still respond to a hand, and
// the whole thing still collapses to stillness under Reduce Motion.
//
// What changed is what the chart is *of*. The figure is no longer nine
// unexplained stars: Mira sits at the centre as the coordinator, and the six
// specialists orbit it on a clear hexagon, named and connected. The
// constellation stays as the engraved ground behind them, so the brand is
// still a chart — it just now says who does the work.
//
// The copy is agent-oriented: research and compare, organise, review and
// approve. Nothing here promises a purchase, a booking or a bank.
struct OrionOnboarding: View {
  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var step: Int

  private let onFinish: () -> Void
  private let steps = 4

  /// The six orbit positions, in degrees, clockwise from the right. A flat-sided
  /// hexagon: no specialist sits directly above the coordinator, so every name
  /// has room and the middle of the figure stays readable.
  private static let angles: [Double] = [0, 60, 120, 180, 240, 300]

  init(initialStep: Int? = nil, onFinish: @escaping () -> Void) {
    self.onFinish = onFinish
    _step = State(initialValue: min(max(initialStep ?? 0, 0), 3))
  }

  private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let canvas = CGSize(
        width: size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
        height: size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
      )

      // The decorative stage lives in the background, where its full-bleed
      // canvas cannot make the layout taller than the screen. The column below
      // is pinned to `proxy.size`, so the footer — and the CTA — are always on
      // screen, at every step and text size.
      VStack(spacing: 0) {
        topBar
        constellation(size: size)
        copyPanel
        footer
      }
      .frame(width: size.width, height: size.height, alignment: .top)
      .background {
        ZStack {
          brand.canvas
          SceneStage(
            planes: [
              // Farthest: the engraved plate. It drifts, and it turns very
              // slowly, so the chart reads as something being measured rather
              // than as a printed page.
              StagePlane(
                id: "chart", image: "px-starchart",
                width: 1.62, at: UnitPoint(x: 0.44, y: 0.26),
                opacity: 0.22, blur: 0.8,
                rotation: -5, drift: 16, period: 44, sway: 2.2
              ),
              // A second, fainter plate behind it, hanging the other way: two
              // planes at different depths make the page feel like a table.
              StagePlane(
                id: "chart-far", image: "px-starchart",
                width: 1.30, at: UnitPoint(x: 0.72, y: 0.14),
                opacity: 0.09, blur: 1.6,
                rotation: 9, drift: 22, period: 62, sway: 1.4
              ),
              // Nearest: the measuring arc, crossing the bottom, sliding and
              // tipping a little as it goes.
              StagePlane(
                id: "arc", image: "px-arc",
                width: 1.85, at: UnitPoint(x: 0.60, y: 0.74),
                opacity: 0.34,
                rotation: 3, drift: 26, period: 26, sway: 3.0
              ),
              // An arc fragment low on the other side, so the two edges of the
              // frame are not symmetrical.
              StagePlane(
                id: "arc-near", image: "px-arc",
                width: 1.10, at: UnitPoint(x: 0.12, y: 0.90),
                opacity: 0.16, blur: 0.6,
                flip: true, rotation: -7, drift: 34, period: 21, sway: 2.4
              ),
            ],
            canvas: canvas,
            reduceMotion: reduceMotion
          )
          .modifier(SceneBreath(amount: reduceMotion ? 0 : 0.008))
        }
        .ignoresSafeArea()
      }
    }
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(alignment: .center, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 3) {
        MiraWordmark(size: 22, color: brand.text, dotColor: brand.accent)
        Text("GO BEYOND.")
          .font(.system(size: 8, weight: .medium))
          .tracking(3.0)
          .foregroundStyle(brand.textTertiary)
      }
      Spacer(minLength: Space.sm)
      Text("6 specialists")
        .font(MiraFont.label(11))
        .foregroundStyle(brand.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(brand.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(brand.hairline, lineWidth: 1) }
    }
    .padding(.horizontal, Space.gutter)
    .padding(.top, Space.sm)
  }

  // MARK: - The constellation of specialists

  /// Mira at the centre, the six specialists around it, and the chart itself as
  /// the engraved ground. Connector lines say what the picture means: every
  /// specialist answers to one coordinator.
  @ViewBuilder
  private func constellation(size: CGSize) -> some View {
    // Step 0 introduces the coordinator alone; the six specialists are revealed
    // when the reader continues, so the first thing the chart says is "one
    // coordinator" rather than "a crowd".
    let specialistsVisible = step > 0

    // At an accessibility text size the hexagon's names would collide, so the
    // figure becomes a plain roster instead. Nothing overlaps at any size.
    if isAccessibilitySize {
      accessibilityRoster(size: size, specialistsVisible: specialistsVisible)
    } else {
      hexagon(size: size, specialistsVisible: specialistsVisible)
    }
  }

  /// The stagger for one specialist: each node follows the previous by ~70 ms.
  /// Under Reduce Motion there is no animation at all — the nodes are simply
  /// shown or hidden.
  private func revealAnimation(index: Int) -> Animation? {
    guard !reduceMotion else { return nil }
    let delay = step > 0 ? Double(index) * 0.07 : 0
    return .easeOut(duration: 0.35).delay(delay)
  }

  /// The default figure: Mira at the centre, the six specialists on a hexagon.
  /// The hero holds most of the page, but on the capabilities step it eases
  /// back so all six cards sit fully above the footer at the default text size.
  private func hexagon(size: CGSize, specialistsVisible: Bool) -> some View {
    let height = size.height * (step == 2 ? 0.33 : 0.42)
    let center = CGPoint(x: size.width / 2, y: height * 0.46)
    let radius = min(size.width * 0.34, height * 0.31)
    let specialists = AgentRoster.forBrand(brand.kind)

    return ZStack {
      Color.clear

      // The brand's own figure, kept as an engraved ground rather than the
      // subject: the avatars in front are what is being explained.
      OrionField(focus: nil, reveal: 9, travelling: !reduceMotion, showsLabels: false)
        .opacity(0.14)
        .allowsHitTesting(false)

      Canvas { context, _ in
        for angle in Self.angles {
          let radians = angle * .pi / 180
          var path = Path()
          path.move(to: center)
          path.addLine(
            to: CGPoint(
              x: center.x + CGFloat(cos(radians)) * radius,
              y: center.y + CGFloat(sin(radians)) * radius
            )
          )
          context.stroke(
            path,
            with: .color(brand.text.opacity(0.14)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
          )
        }
      }
      .opacity(specialistsVisible ? 1 : 0)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: specialistsVisible)
      .allowsHitTesting(false)

      Circle()
        .strokeBorder(brand.text.opacity(0.10), lineWidth: 1)
        .frame(width: radius * 2, height: radius * 2)
        .position(center)

      ForEach(Array(specialists.enumerated()), id: \.element.id) { index, agent in
        specialistNode(agent)
          .opacity(specialistsVisible ? 1 : 0)
          .scaleEffect(specialistsVisible ? 1 : 0.72)
          .animation(revealAnimation(index: index), value: specialistsVisible)
          .position(point(index: index, center: center, radius: radius))
      }

      coordinator
        .position(center)
    }
    .frame(width: size.width, height: height)
    .clipped()
    .allowsHitTesting(false)
    .accessibilityElement(children: .contain)
  }

  /// An accessibility-size stand-in for the hexagon: Mira above a three-column
  /// grid of the six named specialists. A grid cannot overlap itself, so large
  /// type stays readable; the copy below scrolls if it needs to.
  private func accessibilityRoster(size: CGSize, specialistsVisible: Bool) -> some View {
    let specialists = AgentRoster.forBrand(brand.kind)

    return VStack(spacing: Space.sm) {
      // A compact coordinator chip: the large ringed version would crowd the
      // wordmark and steal height the roster needs.
      HStack(spacing: Space.xs) {
        MiraDot(size: 14, color: brand.accentDeep, pulsing: true)
        Text("Mira")
          .font(MiraFont.label(13))
          .foregroundStyle(brand.text)
        Text("Coordinator")
          .font(MiraFont.caption(11))
          .foregroundStyle(brand.textTertiary)
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Mira, coordinator of six specialists")

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 3),
        spacing: Space.sm
      ) {
        ForEach(Array(specialists.enumerated()), id: \.element.id) { index, agent in
          VStack(spacing: 4) {
            AgentAvatar(agent: agent, size: 38)
            Text(agent.name)
              .font(MiraFont.label(11))
              .foregroundStyle(brand.text)
              .lineLimit(1)
              .minimumScaleFactor(0.5)
          }
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(agent.name), \(agent.role)")
          .opacity(specialistsVisible ? 1 : 0)
          .scaleEffect(specialistsVisible ? 1 : 0.75)
          .animation(revealAnimation(index: index), value: specialistsVisible)
        }
      }
    }
    .padding(.horizontal, Space.gutter)
    .frame(width: size.width, height: size.height * 0.30, alignment: .center)
    .clipped()
    .accessibilityElement(children: .contain)
  }

  private func point(index: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
    let radians = Self.angles[index % Self.angles.count] * .pi / 180
    return CGPoint(
      x: center.x + CGFloat(cos(radians)) * radius,
      y: center.y + CGFloat(sin(radians)) * radius
    )
  }

  private func specialistNode(_ agent: AgentSpecialist) -> some View {
    VStack(spacing: 6) {
      AgentAvatar(agent: agent, size: 42)
      Text(agent.name)
        .font(MiraFont.label(11))
        .foregroundStyle(brand.text)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(width: 76)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(agent.name), \(agent.role)")
  }

  private var coordinator: some View {
    VStack(spacing: 4) {
      ZStack {
        Circle().fill(brand.accentTint).frame(width: 58, height: 58)
        Circle().strokeBorder(brand.hairline, lineWidth: 1).frame(width: 58, height: 58)
        MiraDot(size: 16, color: brand.accentDeep, pulsing: true)
      }
      Text("Mira")
        .font(MiraFont.label(13))
        .foregroundStyle(brand.text)
      Text("Coordinator")
        .font(MiraFont.caption(10))
        .foregroundStyle(brand.textTertiary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Mira, coordinator of six specialists")
  }

  // MARK: - Copy

  private var copyPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.md) {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text(headline)
            .font(brand.display(30, weight: .semibold))
            .tracking(brand.displayTracking(30))
            .foregroundStyle(brand.text)
            .fixedSize(horizontal: false, vertical: true)
            .id(step)
            .transition(.opacity.combined(with: .offset(y: 8)))

          Text(supporting)
            .font(MiraFont.body(16))
            .foregroundStyle(brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeOut(duration: 0.3), value: step)

        if step == 2 {
          capabilities
        }
      }
      .padding(.horizontal, Space.gutter)
      .padding(.top, Space.xs)
      .padding(.bottom, Space.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .readableWidth(620)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private var headline: String {
    switch step {
    case 0: return "One coordinator,\nsix specialists."
    case 1: return "Research and\ncompare."
    case 2: return "Six ways\nto help."
    default: return "You approve\nwhat happens."
    }
  }

  private var supporting: String {
    switch step {
    case 0:
      return "Mira listens first, then brings in the specialist who fits the job — not a generic assistant guessing."
    case 1:
      return "Options gathered, checked and compared. Every source is shown, so an answer can be traced back."
    case 2:
      return "Each specialist has one job, and says plainly what it found."
    default:
      return "They prepare and explain. Nothing moves, sends or is scheduled without your go-ahead."
    }
  }

  /// The six capabilities, written the way the specialists themselves would
  /// describe them: what they do, in one line each. Two columns keep all six on
  /// screen at once rather than in a list that has to be scrolled.
  private var capabilities: some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: Space.sm),
        GridItem(.flexible(), spacing: Space.sm),
      ],
      spacing: Space.sm
    ) {
      ForEach(AgentRoster.forBrand(brand.kind)) { agent in
        HStack(alignment: .top, spacing: Space.xs) {
          Image(systemName: agent.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(brand.accentDeep)
            .frame(width: 18)
            .padding(.top, 2)
          VStack(alignment: .leading, spacing: 1) {
            Text(agent.name)
              .font(MiraFont.label(13))
              .foregroundStyle(brand.text)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            Text(agent.role)
              .font(MiraFont.caption(11))
              .foregroundStyle(brand.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(brand.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(agent.role)")
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(spacing: Space.sm) {
      HStack(spacing: Space.sm) {
        stepRail
        Spacer(minLength: Space.xs)
        Text("Step \(step + 1) of \(steps)")
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .monospacedDigit()
      }

      // At an accessibility text size the two controls stack, so neither is
      // squeezed or clipped; both stay full-width and comfortably tappable.
      if isAccessibilitySize {
        VStack(spacing: Space.xs) {
          if step > 0 {
            Button("Back") { goBack() }
              .buttonStyle(MiraButtonStyle(kind: .secondary))
          }
          Button(step == steps - 1 ? "Enter Mira" : "Continue") { advance() }
            .buttonStyle(MiraButtonStyle(kind: .primary))
        }
      } else {
        HStack(spacing: Space.xs) {
          if step > 0 {
            Button("Back") { goBack() }
              .buttonStyle(MiraButtonStyle(kind: .secondary, fullWidth: false))
          }
          Button(step == steps - 1 ? "Enter Mira" : "Continue") { advance() }
            .buttonStyle(MiraButtonStyle(kind: .primary))
        }
      }
    }
    .padding(.horizontal, Space.gutter)
    .padding(.top, Space.sm)
    .padding(.bottom, Space.xs)
    .background(alignment: .top) { Rule() }
  }

  /// Four ticks, one per step. The four onboarding steps are the only thing
  /// being counted — the chart's stars no longer pretend to be progress.
  private var stepRail: some View {
    HStack(spacing: 6) {
      ForEach(0..<steps, id: \.self) { index in
        Circle()
          .fill(index <= step ? brand.text : brand.text.opacity(0.16))
          .frame(width: index == step ? 9 : 6, height: index == step ? 9 : 6)
      }
    }
    .animation(.easeOut(duration: 0.25), value: step)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step + 1) of \(steps)")
  }

  private func advance() {
    if step == steps - 1 {
      onFinish()
    } else {
      withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) { step += 1 }
    }
  }

  private func goBack() {
    withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) { step -= 1 }
  }
}
