import SwiftUI

// MARK: - Chat home
//
// The product after onboarding, for both brands.
//
// It is deliberately one screen. At rest it shows a single figure — what is
// actually available — centred above the composer, with a short row of things
// you might say. As soon as the conversation starts the figure recedes and the
// screen becomes a fluid scroll of turns and cards; the balance lives in
// Accounts from then on rather than following you down the transcript.
//
// Everything money-shaped in this screen is a request. Mira talks; deterministic
// code decides; the user confirms. No sentence posted to the ledger on its own.

struct ChatHomeView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var draft = ""
  @State private var showMenu = false
  @State private var showRoster = false
  @State private var route: HomeRoute?
  @State private var pendingRoute: HomeRoute?
  @State private var pendingSpecialist: AgentSpecialist?
  @State private var pendingProfileChooser = false
  @State private var pendingProfileStory = false
  /// Measured height of the transcript content, used to decide whether the
  /// conversation is long enough to auto-scroll.
  @State private var contentHeight: CGFloat = 0

  @FocusState private var composerFocused: Bool

  private var hasConversation: Bool { !session.conversation.isEmpty }

  private var subscriptionActions: [String] {
    guard let last = session.conversation.last, last.role == .mira,
      last.flow == "subscriptions"
    else { return [] }
    return Array(last.chips.prefix(3))
  }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      // The receding floor only belongs to the resting state. Once there is a
      // conversation, the transcript is the subject.
      if !hasConversation {
        DepthScene.gridField()
          .ignoresSafeArea()
          .opacity(0.75)
          .transition(.opacity)
      }

      VStack(spacing: 0) {
        topBar

        if hasConversation {
          transcript
        } else {
          restingHome
        }

        if !subscriptionActions.isEmpty {
          subscriptionActionDock
        }

        composer
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: hasConversation)
    .sheet(isPresented: $showMenu) {
      MainMenuSheet(
        onRoute: { selected in
          pendingRoute = selected
          showMenu = false
        },
        onSpecialist: { agent in
          pendingSpecialist = agent
          showMenu = false
        },
        onSwitchProfile: {
          pendingProfileChooser = true
          showMenu = false
        },
        onProfileStory: {
          pendingProfileStory = true
          showMenu = false
        }
      )
    }
    .onChange(of: showMenu) { _, presented in
      // Presenting a second sheet from inside the first is unreliable, so the
      // selection is held until the menu has actually gone.
      guard !presented else { return }
      if let pendingSpecialist {
        session.openSpecialist(pendingSpecialist)
        self.pendingSpecialist = nil
      }
      if let pendingRoute {
        route = pendingRoute
        self.pendingRoute = nil
      }
      if pendingProfileChooser {
        pendingProfileChooser = false
        session.requestProfileChooser()
      }
      if pendingProfileStory {
        pendingProfileStory = false
        session.openProfileStory()
      }
    }
    .sheet(isPresented: $showRoster) { RosterSheet() }
    .sheet(item: $route) { destination in
      routeView(destination)
    }
    .onAppear {
      Task { await session.refreshLiveLibraryChatIfNeeded() }
    }
    .onChange(of: session.requestedTab) { _, requested in
      guard let requested else { return }
      route = HomeRoute(tab: requested)
      session.requestedTab = nil
    }
    // A flow that wants a room opened — "open my piggy banks" — asks here,
    // and the request is spent once the sheet is presented.
    .onChange(of: session.requestedRoute) { _, requested in
      guard let requested else { return }
      route = requested
      session.requestedRoute = nil
    }
    .onChange(of: session.activeThreadId) { _, _ in
      // A draft belongs to the conversation it was typed in. Switching threads
      // or starting a new chat must never carry unsent text into another one.
      draft = ""
      Task { await session.refreshLiveLibraryChatIfNeeded() }
    }
  }

  // MARK: Top bar

  private var topBar: some View {
    HStack(spacing: Space.xs) {
      RoundIconButton(glyph: "line.3.horizontal", label: "Menu") {
        showMenu = true
      }

      Spacer(minLength: Space.xs)

      centerMark
        .layoutPriority(1)

      Spacer(minLength: Space.xs)

      trailingControls
    }
    .padding(.horizontal, Space.gutter)
    .padding(.top, Space.xs)
    .padding(.bottom, Space.sm)
  }

  /// At most one control on the right. Everything it holds — conversations,
  /// a new chat and the roster — is reachable from here or from the menu, so the
  /// title keeps the width it needs.
  @ViewBuilder
  private var trailingControls: some View {
    if session.activeAgentId != nil {
      Button {
        session.releaseSpecialist()
      } label: {
        Text("Mira")
          .font(MiraFont.label(13))
          .foregroundStyle(brand.text)
          .padding(.horizontal, Space.sm)
          .frame(minHeight: 44)
          .background(brand.surface, in: Capsule())
          .overlay { Capsule().strokeBorder(brand.hairline, lineWidth: 1) }
      }
      .accessibilityLabel("Back to Mira coordinating the roster")
    } else if hasConversation {
      Menu {
        Button {
          route = .threads
        } label: {
          Label("Conversations", systemImage: "clock.arrow.circlepath")
        }
        Button {
          Task {
            await session.loadEverydayChats()
            route = .threads
          }
        } label: {
          Label(session.hasEverydayChats ? "Open 50 chats" : "Add 50 chats",
            systemImage: "square.stack.3d.up")
        }
        Button {
          session.newConversation()
          draft = ""
        } label: {
          Label("New chat", systemImage: "square.and.pencil")
        }
        Button {
          showRoster = true
        } label: {
          Label("Specialists", systemImage: "person.2")
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(brand.text)
          .frame(width: 44, height: 44)
          .background(brand.surface, in: Circle())
          .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
      }
      .accessibilityLabel("Conversation options: conversations, 50 chats, new chat, specialists")
    } else {
      RoundIconButton(glyph: "person.2", label: "Specialists") {
        showRoster = true
      }
    }
  }

  @ViewBuilder
  private var centerMark: some View {
    if let id = session.activeAgentId {
      let agent = AgentRoster.agent(brand: session.brandKind, id: id)
      HStack(spacing: Space.xs) {
        AgentAvatar(agent: agent, size: 26)
        VStack(alignment: .leading, spacing: 0) {
          Text(agent.name)
            .font(MiraFont.label(14))
            .foregroundStyle(brand.text)
          Text(agent.role)
            .font(MiraFont.caption(11))
            .foregroundStyle(brand.textTertiary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Speaking with \(agent.name), \(agent.role)")
    } else if hasConversation {
      // The title of the chat you are actually in, so the bar orients you. It
      // gets the room it needs; a long title truncates only once space is gone.
      Text(session.activeThreadTitle)
        .font(MiraFont.label(13))
        .foregroundStyle(brand.text)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.85)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Conversation: \(session.activeThreadTitle)")
    } else {
      MiraWordmark(size: 19, color: brand.text, dotColor: brand.accent)
    }
  }

  // MARK: Resting home

  private var restingHome: some View {
    VStack(spacing: Space.lg) {
      Spacer(minLength: Space.lg)

      balanceFigure

      chips

      if let notice = session.relayNotice {
        Note(notice, tone: .positive)
          .padding(.horizontal, Space.gutter)
          .readableWidth(560)
      }

      // No status line here: while Mira works, the transcript's working row says
      // so, and at rest the figure above is the message.
      Spacer(minLength: Space.md)
    }
    .frame(maxWidth: .infinity)
  }

  private var balanceFigure: some View {
    VStack(spacing: Space.xs) {
      Text("Available")
        .font(MiraFont.body(15))
        .foregroundStyle(brand.textSecondary)

      HeroNumber(session.clearedUSD.display, size: 56, alignment: .center)
        .animation(.easeOut(duration: 0.35), value: session.clearedUSD.minorUnits)

      OtherHoldingsLine()
    }
    .padding(.horizontal, Space.gutter)
  }

  private var chips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Space.xs) {
        ActionChip(title: "Send to \(session.otherAppName)", glyph: "paperplane") {
          send("Send money to \(session.otherAppName)")
        }
        ActionChip(title: "Where is my money?", glyph: "circle.hexagongrid") {
          send("Where is my money right now?")
        }
        ActionChip(title: "Left this week?", glyph: "calendar") {
          send("How much is left in this week's budget?")
        }
        ActionChip(title: "Freeze my card", glyph: "snowflake") {
          send("Freeze my card")
        }
        ActionChip(title: "Receiving details", glyph: "arrow.down.circle") {
          send("How do I receive money?")
        }
        ActionChip(title: "Plan a trip", glyph: "airplane") {
          send("Help me plan flights for my trip")
        }
      }
      .padding(.horizontal, Space.gutter)
    }
  }

  // MARK: Transcript

  private var transcript: some View {
    GeometryReader { outer in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            if session.isShowingExampleConversation { goalThumbnails }
            let chipTurnIds = session.chipTurnIds
            ForEach(session.conversation) { turn in
              ChatTurnView(
                turn: turn, showsChips: chipTurnIds.contains(turn.id))
                .id(turn.id)
                // An answer arrives rather than pops: a short fade with a small
                // rise. A user's own message is already on screen by the time it
                // is read, so it does not travel.
                .transition(
                  turn.role == .mira
                    ? .opacity.combined(with: .offset(y: 6))
                    : .identity)
            }

            if let notice = session.relayNotice, session.relayNoticeIsFresh {
              Note(notice, tone: .positive)
            }

            if session.isWorking {
              workingRow
            }

            Color.clear
              .frame(height: 1)
              .id(Self.bottomAnchor)
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(640)
          // A new turn fades in and rises the last few points rather than
          // appearing mid-layout. Motion is the only thing that changes here;
          // with Reduce Motion on, the turn simply appears.
          .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.conversation.count)
          // A short transcript starts at the top with comfortable padding
          // instead of hanging off the bottom of the screen.
          .padding(.top, Space.md)
          .padding(.bottom, Space.lg)
          .background(
            GeometryReader { content in
              Color.clear.preference(
                key: TranscriptHeightKey.self, value: content.size.height)
            }
          )
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(TranscriptHeightKey.self) { height in
          contentHeight = height
          scrollToLatest(proxy, viewport: outer.size.height, animated: false)
        }
        .onChange(of: session.conversation.count) { _, _ in
          scrollToLatest(proxy, viewport: outer.size.height, animated: !reduceMotion)
        }
        .onChange(of: session.isWorking) { _, _ in
          scrollToLatest(proxy, viewport: outer.size.height, animated: !reduceMotion)
        }
      }
    }
  }

  /// Auto-scroll only when the conversation is actually longer than the screen.
  /// A first turn, or a short exchange, stays at the top where it belongs.
  private func scrollToLatest(_ proxy: ScrollViewProxy, viewport: CGFloat, animated: Bool) {
    guard !session.isShowingExampleConversation else { return }
    guard contentHeight > viewport + 40 else { return }
    let target: AnyHashable
    let anchor: UnitPoint
    if let last = session.conversation.last,
      last.receipt != nil || last.action?.kind == .agentTask {
      target = last.id
      anchor = .top
    } else {
      target = Self.bottomAnchor
      anchor = .bottom
    }
    if animated {
      withAnimation(.easeOut(duration: 0.25)) {
        proxy.scrollTo(target, anchor: anchor)
      }
    } else {
      proxy.scrollTo(target, anchor: anchor)
    }
  }

  private static let bottomAnchor = "chat-bottom"

  private var goalThumbnails: some View {
    HStack(spacing: Space.xs) {
      ForEach(session.persona.goals) { goal in
        Button { route = .piggyBanks } label: {
          VStack(spacing: 5) {
            if let asset = goal.artAsset, let artwork = MiraArt.image(named: asset) {
              Image(uiImage: artwork)
                .resizable()
                .scaledToFit()
                .frame(height: 76)
            }
            Text(goal.name)
              .font(MiraFont.caption(11))
              .foregroundStyle(brand.text)
              .lineLimit(2)
              .frame(height: 30, alignment: .top)
          }
          .frame(maxWidth: .infinity)
          .padding(Space.xs)
          .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(goal.name) in Piggy Banks")
      }
    }
  }

  private var workingRow: some View {
    HStack(spacing: Space.xs) {
      AgentAvatar(agent: session.activeSpecialist, size: 24)
      MiraDot(size: 8, pulsing: true)
      Text("\(session.activeSpecialist.name) is working…")
        .font(MiraFont.body(14))
        .foregroundStyle(brand.textSecondary)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Composer

  private var subscriptionActionDock: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Space.xs) {
        ForEach(subscriptionActions, id: \.self) { action in
          Button {
            send(action)
          } label: {
            Text(action)
              .font(MiraFont.label(13))
              .foregroundStyle(brand.text)
              .lineLimit(1)
              .padding(.horizontal, Space.sm)
              .frame(minHeight: 40)
              .background(brand.surface, in: Capsule())
              .overlay { Capsule().strokeBorder(brand.hairline, lineWidth: 1) }
          }
          .buttonStyle(.plain)
          .disabled(session.isWorking)
          .accessibilityLabel(action)
        }
      }
      .padding(.horizontal, Space.gutter)
    }
    .padding(.vertical, Space.xs)
    .background(brand.canvas)
    .overlay(alignment: .top) {
      Rectangle().fill(brand.hairline).frame(height: 1)
    }
  }

  private var composer: some View {
    VStack(spacing: 0) {
      Rule()

      HStack(alignment: .bottom, spacing: Space.xs) {
        TextField(
          "",
          text: $draft,
          prompt: Text(
            session.activeAgentId == nil
              ? "Ask Mira anything" : "Ask \(session.activeSpecialist.name)"
          )
          // An explicit prompt colour, so the hint is readable rather than the
          // system's faint placeholder grey.
          .foregroundStyle(brand.textSecondary),
          axis: .vertical
        )
        .lineLimit(1...5)
        .font(MiraFont.body(16))
        .foregroundStyle(brand.text)
        .focused($composerFocused)
        .submitLabel(.send)
        // What the person typed is what gets sent: the composer does not
        // autocorrect a name or a place into a different one.
        .autocorrectionDisabled(true)
        .onSubmit { send() }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 11)
        .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(brand.hairline, lineWidth: 1)
        }

        Button {
          send()
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(brand.canvas)
            .frame(width: 44, height: 44)
            .background(canSend ? brand.ink : brand.textTertiary.opacity(0.35), in: Circle())
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
      }
      .padding(.horizontal, Space.gutter)
      .padding(.top, Space.sm)
      .padding(.bottom, Space.xs)
      .readableWidth(640)
    }
    .background(brand.canvas)
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isWorking
  }

  private func send(_ explicit: String? = nil) {
    let message = (explicit ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !session.isWorking else { return }
    if session.isShowingExampleConversation { session.newConversation() }
    if explicit == nil { draft = "" }
    composerFocused = false
    Task { await session.sendChat(message) }
  }

  // MARK: Menu destinations

  @ViewBuilder
  private func routeView(_ destination: HomeRoute) -> some View {
    switch destination {
    case .accounts: AccountsView()
    case .move: MoveView()
    case .plan: PlanView()
    case .piggyBanks: PiggyBanksView()
    case .cards: CardsScreen()
    case .bills: ContactsBillsView(mode: .bills)
    case .contacts: ContactsBillsView(mode: .contacts)
    case .activity: ActivityView()
    case .threads: ThreadsHistoryView()
    case .controls: YouView()
    case .specialists: RosterSheet()
    }
  }
}

// MARK: - Chips

private struct TranscriptHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct ActionChip: View {
  let title: String
  let glyph: String
  let action: () -> Void

  @Environment(\.brand) private var brand

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: glyph)
          .font(.system(size: 12, weight: .medium))
        Text(title)
          .font(MiraFont.label(14))
      }
      .foregroundStyle(brand.text)
      .padding(.horizontal, Space.md)
      .frame(minHeight: 44)
      .background(brand.surface, in: Capsule())
      .overlay { Capsule().strokeBorder(brand.hairline, lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}

// MARK: - Other holdings

/// One quiet line for everything that is not the USD figure above it. Read from
/// the ledger, never computed by a model.
private struct OtherHoldingsLine: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  private var others: [(asset: Asset, amount: Money)] {
    session.ledger.holdings().filter { $0.asset != .usd && $0.amount.minorUnits != 0 }
  }

  var body: some View {
    if others.isEmpty {
      Text("Live balance")
        .font(MiraFont.caption(12))
        .foregroundStyle(brand.textTertiary)
    } else {
      Text(
        others.map { "\($0.amount.display)" }.joined(separator: "  ·  ")
      )
      .font(MiraFont.figure(13, weight: .medium))
      .foregroundStyle(brand.textTertiary)
      .multilineTextAlignment(.center)
    }
  }
}
