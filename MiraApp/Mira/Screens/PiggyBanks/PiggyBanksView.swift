import SwiftUI

// MARK: - Piggy Banks
//
// One dream at a time, alone on the canvas.
//
// The shelf used to be a row of cards. It is now a full-width pager: no card
// around the dream, no peek at the neighbours, and the art — which is the
// subject, not an ornament — is the largest thing on the screen, sitting
// directly on the brand ground.
//
// Every page keeps one shape whether the drawing is in flight or finished, and
// the whole block is centred in the space the header and the dots leave. A
// drawing that lands therefore fades in where it will live instead of pushing
// the page around. Nothing here moves money; a piggy bank is a record, not a
// payment.

struct PiggyBanksView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var art = GoalArtService()
  @State private var showingCreate = false
  @State private var selected: Goal?
  /// The page the pager has settled on, named by `ShelfPage.id`.
  @State private var currentPage: String?
  /// The last dream on the shelf when the create sheet opened, so a dream made
  /// inside it can be brought into view rather than left off-screen.
  @State private var shelfBeforeCreate: String?

  private var goals: [Goal] { session.localDirectory.goals }

  /// A dream, or the offer of a new one. Plain string ids so the pager can
  /// track the trailing page with the same binding it tracks a goal with.
  private enum ShelfPage: Identifiable {
    case dream(Goal)
    case newDream

    var id: String {
      switch self {
      case .dream(let goal): return goal.id.uuidString
      case .newDream: return "new-dream"
      }
    }
  }

  private var pages: [ShelfPage] { goals.map(ShelfPage.dream) + [.newDream] }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Piggy Banks", subtitle: "The dreams in progress.",
          onClose: { dismiss() })

        if goals.isEmpty {
          emptyState
        } else {
          shelf
        }
      }
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showingCreate) {
      NewDreamSheet(art: art, currency: session.persona.weeklyBudget.currency)
    }
    .sheet(item: $selected) { goal in
      GoalDetailSheet(goal: goal, art: art)
    }
    .onChange(of: showingCreate) { _, presented in
      guard !presented else { return }
      let newest = goals.last?.id.uuidString
      guard let shelfBeforeCreate, let newest, newest != shelfBeforeCreate else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { currentPage = newest }
    }
  }

  // MARK: The shelf

  /// Full-width pages, one dream each. The pager takes everything the header
  /// and the dots leave, and each page centres its own block inside that, so a
  /// goal sits halfway down the space rather than against the top margin.
  private var shelf: some View {
    VStack(spacing: 0) {
      GeometryReader { outer in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 0) {
            ForEach(pages) { page in
              pagerPage(page, in: outer.size)
                .containerRelativeFrame(.horizontal)
                .modifier(PageDepth(enabled: !reduceMotion))
            }
          }
          .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentPage)
      }

      PageDots(count: pages.count, current: currentIndex)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.lg)
    }
  }

  @ViewBuilder
  private func pagerPage(_ page: ShelfPage, in size: CGSize) -> some View {
    switch page {
    case .dream(let goal):
      Button {
        selected = goal
      } label: {
        DreamPage(goal: goal, art: art, available: size)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(goal.name), \(savingsLine(for: goal))")

    case .newDream:
      NewDreamPage { beginCreate() }
    }
  }

  private var currentIndex: Int {
    guard let currentPage, let index = pages.firstIndex(where: { $0.id == currentPage })
    else { return 0 }
    return index
  }

  private var emptyState: some View {
    VStack(spacing: Space.md) {
      Text("Nothing on the shelf yet.")
        .font(MiraFont.body(17))
        .foregroundStyle(brand.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Start a dream") { beginCreate() }
        .buttonStyle(MiraButtonStyle(kind: .primary, fullWidth: false))
    }
    .padding(.horizontal, Space.gutter)
    .readableWidth()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Opening the sheet also marks the shelf, so a dream made inside it can be
  /// brought into view when the sheet closes.
  private func beginCreate() {
    shelfBeforeCreate = goals.last?.id.uuidString
    showingCreate = true
  }
}

// MARK: - The paging transition

/// The depth a page carries as it passes: the arriving page eases up from 0.96
/// and settles at 1, the leaving page gives the same amount away and drifts a
/// few points further out, and both fade at the edges so only one dream ever
/// reads as present. Quiet on purpose — no bounce; this is a bank, not a deck of
/// cards. Under Reduce Motion there is no transition at all: a page simply cuts
/// to the next.
private struct PageDepth: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      depth(content)
    } else {
      content
    }
  }

  private func depth(_ content: Content) -> some View {
    content.scrollTransition(.interactive, axis: .horizontal) { content, phase in
      let distance = min(1, abs(phase.value))
      return content
        .scaleEffect(CGFloat(1 - 0.04 * distance))
        .offset(x: CGFloat(phase.value * 4))
        .opacity(1 - 0.4 * distance * distance)
    }
  }
}

// MARK: - One dream

/// A single dream, directly on the canvas: no card, no border, no surface
/// behind it. The whole block — art, name, figure, line — is centred in the
/// page, and the art is allowed the larger half of it.
struct DreamPage: View {
  let goal: Goal
  let art: GoalArtService
  let available: CGSize

  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: Space.md) {
      artwork

      VStack(spacing: Space.xs) {
        Text(goal.name)
          .font(MiraFont.display(23))
          .foregroundStyle(brand.text)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)

        Text(savingsLine(for: goal))
          .font(MiraFont.body(16))
          .foregroundStyle(brand.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      // If a page ever has to give something up — a very large Dynamic Type
      // setting on a small screen — it is the art that gives way, never the
      // words.
      .layoutPriority(1)

      if goal.targetMinor > 0 {
        ProgressLine(fraction: progress)
          .frame(width: min(contentWidth, 220))
      }
    }
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, Space.gutter)
    // A drawing that lands fades in; the page keeps its shape either way.
    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: artState)
  }

  /// The art, the state of a drawing in flight, or nothing at all. A missing
  /// image is a quieter page — never a placeholder shape standing in for the
  /// dream.
  @ViewBuilder
  private var artwork: some View {
    if let image = art.image(for: goal) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity)
        .frame(height: artBox)
        .transition(.opacity)
    } else if art.isDrawing(goal) {
      // Reserves the space the finished drawing will take, so the name and the
      // figure do not move when it arrives.
      VStack(spacing: Space.sm) {
        MiraDot(size: 10, pulsing: true)
        VStack(spacing: 4) {
          Text("Mira is drawing it")
            .font(MiraFont.body(15))
            .foregroundStyle(brand.textSecondary)
          Text("Drawn from scratch — usually under two minutes.")
            .font(MiraFont.caption(12))
            .foregroundStyle(brand.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: artBox)
      .transition(.opacity)
      .accessibilityElement(children: .combine)
    }
  }

  /// The art is the subject, so it takes the full width the gutter leaves and
  /// as much as half the page's height. On a wide screen the page itself stops
  /// at a readable width, and the art stops with it.
  private var artBox: CGFloat { min(contentWidth, available.height * 0.5) }

  private var contentWidth: CGFloat {
    max(0, min(available.width - Space.gutter * 2, 560))
  }

  /// What the art area is showing, as one value, so the change from a drawing
  /// in flight to a finished drawing can be a fade rather than a pop.
  private var artState: String {
    if art.image(for: goal) != nil { return "art" }
    return art.isDrawing(goal) ? "drawing" : "none"
  }

  private var progress: Double {
    guard goal.targetMinor > 0 else { return 0 }
    return min(1, Double(goal.savedMinor) / Double(goal.targetMinor))
  }
}

/// "USD 1,050.00 of USD 2,400.00" — or, when the dream has no target yet,
/// simply what is saved. The two are never mixed.
func savingsLine(for goal: Goal) -> String {
  goal.targetMinor > 0
    ? "\(goal.saved.display) of \(goal.target.display)"
    : "\(goal.saved.display) saved"
}

// MARK: - The trailing page

/// The page after the last dream: not a card, just the offer, centred on the
/// canvas with one quiet action. It opens the same create sheet the shelf has
/// always opened.
struct NewDreamPage: View {
  var onCreate: () -> Void

  @Environment(\.brand) private var brand

  var body: some View {
    VStack(spacing: Space.md) {
      MiraDot(size: 10)

      VStack(spacing: Space.xs) {
        Text("New dream")
          .font(MiraFont.display(23))
          .foregroundStyle(brand.text)
        Text("What are you saving for?")
          .font(MiraFont.body(16))
          .foregroundStyle(brand.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button("Start a dream", action: onCreate)
        .buttonStyle(MiraButtonStyle(kind: .secondary, fullWidth: false))
    }
    .padding(.horizontal, Space.gutter)
    .readableWidth()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Where you are

/// The dots. Not a control and not chrome: a quiet count of what is still to
/// see, so the rest of the shelf is never found by accident. The current page
/// is marked by weight as well as tone, so the state does not rest on colour.
struct PageDots: View {
  let count: Int
  let current: Int

  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 7) {
      ForEach(0..<count, id: \.self) { index in
        Circle()
          .fill(index == current ? brand.accentDeep : brand.textTertiary.opacity(0.35))
          .frame(
            width: index == current ? 6 : 5,
            height: index == current ? 6 : 5)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: current)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Page \(current + 1) of \(count)")
  }
}

// MARK: - The progress line

/// A thin line, not a control: the share of the target that is already put
/// away. It is decorative, so it is hidden from VoiceOver and the figure above
/// it carries the meaning.
struct ProgressLine: View {
  let fraction: Double

  @Environment(\.brand) private var brand

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(brand.hairline)
        Capsule()
          .fill(brand.accentDeep)
          .frame(width: max(0, min(1, fraction)) * geo.size.width)
      }
    }
    .frame(height: 3)
    .accessibilityHidden(true)
  }
}

// MARK: - Creating a dream

struct NewDreamSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  let art: GoalArtService
  let currency: Asset

  @State private var name = ""
  @State private var targetText = ""
  @FocusState private var nameFocused: Bool

  private var cleanedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "What are you saving for?",
          subtitle: "One line is enough — the rest can wait.",
          onClose: { dismiss() })

        VStack(alignment: .leading, spacing: Space.md) {
          TextField("", text: $name, prompt: Text("a month in Tokyo"))
            .font(MiraFont.body(17))
            .foregroundStyle(brand.text)
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit(create)
            .padding(.horizontal, Space.md)
            .padding(.vertical, 13)
            .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(brand.hairline, lineWidth: 1)
            }

          TextField("", text: $targetText, prompt: Text("Target, optional — e.g. 3,000"))
            .font(MiraFont.body(17))
            .foregroundStyle(brand.text)
            .keyboardType(.decimalPad)
            .padding(.horizontal, Space.md)
            .padding(.vertical, 13)
            .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(brand.hairline, lineWidth: 1)
            }

          Button("Create the dream") { create() }
            .buttonStyle(MiraButtonStyle(kind: .primary, fullWidth: true))
            .disabled(cleanedName.isEmpty)
            .opacity(cleanedName.isEmpty ? 0.5 : 1)

          Text("The dream is saved on this device. Mira draws it; nothing here moves money.")
            .font(MiraFont.caption(12))
            .foregroundStyle(brand.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth()
        .padding(.top, Space.xs)
      }
    }
    .navigationBarHidden(true)
    .onAppear { nameFocused = true }
  }

  private func create() {
    guard !cleanedName.isEmpty else { return }
    art.create(
      name: cleanedName,
      target: parsedTarget,
      currency: currency,
      in: session.localDirectory)
    dismiss()
  }

  /// A target is optional, and a half-typed one is simply not a target yet.
  private var parsedTarget: Money? {
    let raw = targetText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: "")
    guard let value = Decimal(string: raw), value > 0 else { return nil }
    return Money(majorUnits: value, currency: currency)
  }
}

// MARK: - One dream, opened

struct GoalDetailSheet: View {
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  let goal: Goal
  let art: GoalArtService

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(title: goal.name, subtitle: "A dream in progress", onClose: { dismiss() })

        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            if let image = art.image(for: goal) {
              Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 340)
            }

            VStack(alignment: .leading, spacing: Space.xs) {
              HeroNumber(goal.saved.display, size: 44)
              if goal.targetMinor > 0 {
                Text("of \(goal.target.display)")
                  .font(MiraFont.body(16))
                  .foregroundStyle(brand.textSecondary)
                ProgressLine(fraction: progress)
              } else {
                Text("saved — no target set")
                  .font(MiraFont.body(16))
                  .foregroundStyle(brand.textSecondary)
              }
            }

            Panel {
              VStack(alignment: .leading, spacing: Space.sm) {
                FieldLine(label: "Saved", value: goal.saved.display)
                if goal.targetMinor > 0 {
                  FieldLine(label: "Target", value: goal.target.display)
                  FieldLine(label: "Still to go", value: goal.remaining.display)
                }
                FieldLine(
                  label: "Protection",
                  value: goal.protected ? "Protected" : "Open")
              }
            }

            if let story = goal.story, !story.isEmpty {
              Text(story)
                .font(MiraFont.body(17))
                .foregroundStyle(brand.text)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("This is a record of the dream, not a payment. Moving money into it happens from the plan.")
              .font(MiraFont.caption(12))
              .foregroundStyle(brand.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth()
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
    .navigationBarHidden(true)
  }

  private var progress: Double {
    guard goal.targetMinor > 0 else { return 0 }
    return min(1, Double(goal.savedMinor) / Double(goal.targetMinor))
  }
}
