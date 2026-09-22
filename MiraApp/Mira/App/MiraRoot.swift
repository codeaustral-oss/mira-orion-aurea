import SwiftUI

// MARK: - Root
//
// One root, two products. The brand arrives through the environment, so this
// file never asks which app it is running inside: it reads the available
// destinations from the theme and builds the shell from that.

struct MiraRoot: View {
  @Environment(MiraSession.self) private var session
  @Environment(MotionSource.self) private var motion
  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  @AppStorage("mira.onboarded") private var hasOnboarded = false
  @State private var previewingOnboarding = LaunchOptions.current.previewOnboarding
  /// Shown on every cold launch before the chat, unless a launch argument named
  /// the profile outright. `-profileChooser` forces it back on.
  @State private var choosingProfile = !LaunchOptions.current.skipsProfileChooser

  private let options = LaunchOptions.current

  /// A preview flag shows the onboarding without changing the stored completion
  /// state, so a debug launch never resets a real user's progress.
  private var showsOnboarding: Bool { !hasOnboarded || previewingOnboarding }

  private func finishOnboarding() {
    if previewingOnboarding {
      withAnimation(.easeOut(duration: 0.5)) { previewingOnboarding = false }
    }
    withAnimation(.easeOut(duration: 0.5)) { hasOnboarded = true }
  }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      if !showsOnboarding {
        // Both products now open on the same thing: Mira, as a conversation.
        // Accounts, the card, the plan and the roster are all one tap away
        // behind the menu, but the assistant is the product, not a tab in it.
        if choosingProfile {
          ProfileChooserView {
            choosingProfile = false
          }
          .transition(.opacity)
        } else {
          ChatHomeView()
            .transition(.opacity)
        }
      } else {
        switch brand.kind {
        case .orion:
          OrionOnboarding(initialStep: options.onboardingStep) {
            finishOnboarding()
          }
        case .aurea:
          AureaOnboarding(
            initialStep: options.onboardingStep,
            sceneOverride: options.onboardingScene
          ) {
            finishOnboarding()
          }
        }
      }
    }
    .onAppear {
      if reduceMotion { motion.isEnabled = false }
      motion.start()
    }
    .task {
      // Start listening for transfers from the other app, and for any agent
      // task that was still running when the app last closed. Harmless when the
      // proxy is not running: a poll simply returns nothing.
      if hasOnboarded {
        session.startRelayPolling()
        session.resumeTaskPolling()
        await session.refreshReminders()
      }
    }
    // `.task` runs once, and at that moment a first-launch user has not
    // onboarded yet, so polling never started. Begin it when they finish.
    .onChange(of: hasOnboarded) { _, onboarded in
      if onboarded {
        session.startRelayPolling()
        session.resumeTaskPolling()
        Task { await session.refreshReminders() }
      }
    }
    // The menu's "Switch profile" row asks for the question again.
    .onChange(of: session.wantsProfileChooser) { _, requested in
      guard requested else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
        choosingProfile = true
      }
    }
    .onDisappear {
      session.stopRelayPolling()
      session.pauseTaskPolling()
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        motion.start()
        session.resumeTaskPolling()
        // The plan may have gone stale while the app was away; the records it
        // reads are all local, and a stale scheduled reminder is worse than none.
        Task { await session.refreshReminders() }
      case .background:
        motion.stop()
        session.pauseTaskPolling()
        session.enterBackground()
      case .inactive:
        motion.stop()
        session.pauseTaskPolling()
      @unknown default:
        motion.stop()
      }
    }
    .alert(
      "Reminders from Mira",
      isPresented: Binding(
        get: { ReminderCenter.shared.needsExplanation },
        set: { showing in if !showing { ReminderCenter.shared.declineExplanation() } }
      )
    ) {
      Button("Allow reminders") {
        Task {
          await ReminderCenter.shared.confirmExplanation()
          await session.refreshReminders()
        }
      }
      Button("Not now", role: .cancel) {}
    } message: {
      Text(
        "Mira can send three things while it is closed: a nudge on the day a subscription charges, a reminder three days before a price-claim window closes, and a quiet line when a watch could not be checked. Nothing else."
      )
    }
  }
}

// MARK: - Shell

/// Four destinations, named by the brand.
///
/// Orion calls the second one Move and the fourth You; Aurea calls them Move
/// Money and Profile. Both call the third one Mira, because the assistant is the
/// product, not a feature of it.
struct BrandShell: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var selection = "accounts"

  var body: some View {
    TabView(selection: $selection) {
      ForEach(brand.tabs, id: \.key) { tab in
        NavigationStack {
          screen(for: tab.key)
        }
        .tag(tab.key)
        .tabItem { Label(tab.title, systemImage: tab.glyph) }
      }
    }
    .tint(brand.kind == .orion ? brand.ink : brand.accent)
    .onChange(of: session.requestedTab) { _, requested in
      guard let requested else { return }
      selection = requested.rawValue
      session.requestedTab = nil
    }
  }

  @ViewBuilder
  private func screen(for key: String) -> some View {
    switch (brand.kind, MainTab(rawValue: key)) {
    case (.aurea, .accounts): AureaHome()
    case (.aurea, .move): AureaMove()
    case (.aurea, .you): AureaProfile()
    case (_, .accounts): AccountsView()
    case (_, .move): MoveView()
    case (_, .mira): MiraAgentView()
    case (_, .you): YouView()
    case (_, nil): AccountsView()
    }
  }
}

// MARK: - Screen top

/// The only persistent chrome: the mark, and one way out.
struct ScreenTop: View {
  var trailing: AnyView?

  @Environment(\.brand) private var brand

  init() { self.trailing = nil }

  init<T: View>(@ViewBuilder trailing: () -> T) {
    self.trailing = AnyView(trailing())
  }

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        MiraWordmark(size: 20, color: brand.text, dotColor: brand.accent)
        Text(brand.tagline.uppercased())
          .font(.system(size: 8, weight: .medium))
          .tracking(2.4)
          .foregroundStyle(brand.textTertiary.opacity(0.85))
      }
      Spacer()
      trailing
    }
    .padding(.horizontal, Space.gutter)
    .padding(.top, Space.xs)
    .padding(.bottom, Space.sm)
  }
}

/// A clean header for a utility sheet.
///
/// The wordmark, tagline and vertical kicker are onboarding chrome. Stacked on
/// top of a sheet's own title they crowded the modal edge and repeated
/// themselves, so a sheet gets one thing instead: a clear title, an optional
/// line of context, and one way out. The generous top padding keeps it clear of
/// the safe area.
struct SheetHeader: View {
  let title: String
  var subtitle: String? = nil
  var onClose: (() -> Void)? = nil
  var accessory: AnyView? = nil

  @Environment(\.brand) private var brand

  init(title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.onClose = onClose
    self.accessory = nil
  }

  init<T: View>(
    title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil,
    @ViewBuilder accessory: () -> T
  ) {
    self.title = title
    self.subtitle = subtitle
    self.onClose = onClose
    self.accessory = AnyView(accessory())
  }

  var body: some View {
    HStack(alignment: .top, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .screenTitle(26)
          .foregroundStyle(brand.text)
          .fixedSize(horizontal: false, vertical: true)
        if let subtitle {
          Text(subtitle)
            .font(MiraFont.body(14))
            .foregroundStyle(brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: Space.sm)
      accessory
      if let onClose {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(brand.text)
            .frame(width: 44, height: 44)
            .background(brand.surface, in: Circle())
            .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
        }
        .accessibilityLabel("Close")
      }
    }
    .padding(.horizontal, Space.gutter)
    .padding(.top, 24)
    .padding(.bottom, Space.md)
  }
}

/// The three-word column that runs beside a headline, as the brand references
/// both use. Written vertically on purpose: it is a mark, not a sentence.
struct BrandKicker: View {
  @Environment(\.brand) private var brand

  var body: some View {
    VStack(alignment: .trailing, spacing: 3) {
      ForEach(brand.kicker, id: \.self) { word in
        Text(word.uppercased())
          .font(.system(size: 9, weight: .medium))
          .tracking(2.2)
          .foregroundStyle(brand.textTertiary.opacity(0.9))
      }
      Rectangle()
        .fill(brand.accent.opacity(0.6))
        .frame(width: 22, height: 1)
    }
  }
}

/// The line that closes a screen.
struct BrandClosing: View {
  @Environment(\.brand) private var brand

  var body: some View {
    HStack(spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(closingLines, id: \.self) { line in
          Text(line.uppercased())
            .font(.system(size: 8, weight: .medium))
            .tracking(2.0)
            .foregroundStyle(brand.textTertiary.opacity(0.8))
        }
      }
      Rectangle()
        .fill(brand.hairline)
        .frame(height: 1)
    }
  }

  private var closingLines: [String] {
    let words = brand.closing.split(separator: " ")
    guard words.count >= 3 else { return [brand.closing] }
    let mid = words.count / 2
    return [words[..<mid].joined(separator: " "), words[mid...].joined(separator: " ")]
  }
}

/// A quiet circular affordance for the screen top.
struct RoundIconButton: View {
  let glyph: String
  let label: String
  var action: () -> Void

  @Environment(\.brand) private var brand

  var body: some View {
    Button(action: action) {
      Image(systemName: glyph)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(brand.text)
        // 44pt is the minimum comfortable target; the visual circle stays
        // small because the extra space is padding, not chrome.
        .frame(width: 44, height: 44)
        .background(brand.surface, in: Circle())
        .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
    }
    .accessibilityLabel(label)
  }
}

// MARK: - Layout

struct ReadableWidth: ViewModifier {
  var max: CGFloat = 560
  func body(content: Content) -> some View {
    content.frame(maxWidth: max).frame(maxWidth: .infinity)
  }
}

extension View {
  func readableWidth(_ max: CGFloat = 560) -> some View { modifier(ReadableWidth(max: max)) }
}
