import SwiftUI

// MARK: - Routes
//
// Everything the app can still do lives behind the top-left menu. The chat home
// is the product; these are the rooms you can walk into from it.

enum HomeRoute: String, CaseIterable, Identifiable, Hashable {
  case accounts
  case move
  case plan
  case piggyBanks
  case cards
  case bills
  case contacts
  case activity
  case threads
  case controls
  case specialists

  var id: String { rawValue }

  var title: String {
    switch self {
    case .accounts: return "Accounts"
    case .move: return "Move money"
    case .plan: return "Plan"
    case .piggyBanks: return "Piggy Banks"
    case .cards: return "Card"
    case .bills: return "Bills"
    case .contacts: return "Contacts"
    case .activity: return "Activity"
    case .threads: return "Conversations"
    case .controls: return "Controls"
    case .specialists: return "Specialists"
    }
  }

  var subtitle: String {
    switch self {
    case .accounts: return "Where your money sits"
    case .move: return "Send, swap, receive — Mira prepares it"
    case .plan: return "Allocations and the budget"
    case .piggyBanks: return "The dreams in progress"
    case .cards: return "Freeze it, or see the details"
    case .bills: return "Your own recurring costs"
    case .contacts: return "People you send to"
    case .activity: return "Your transactions"
    case .threads: return "Open a saved chat, or start a new one"
    case .controls: return "Permissions, automations, preferences"
    case .specialists: return "The assistants behind Mira"
    }
  }

  var glyph: String {
    switch self {
    case .accounts: return "building.columns"
    case .move: return "paperplane"
    case .plan: return "chart.pie"
    case .piggyBanks: return "flag.checkered"
    case .cards: return "creditcard"
    case .bills: return "doc.text"
    case .contacts: return "person.crop.circle"
    case .activity: return "list.bullet.rectangle"
    case .threads: return "clock.arrow.circlepath"
    case .controls: return "slider.horizontal.3"
    case .specialists: return "person.2"
    }
  }

  /// A screen that used to ask the tab shell to move can still do so.
  init?(tab: MainTab) {
    switch tab {
    case .accounts: self = .accounts
    case .move: self = .move
    case .you: self = .controls
    case .mira: return nil
    }
  }
}

// MARK: - The menu

struct MainMenuSheet: View {
  let onRoute: (HomeRoute) -> Void
  let onSpecialist: (AgentSpecialist) -> Void
  let onSwitchProfile: () -> Void
  let onProfileStory: () -> Void

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(brand.productName).font(brand.display(27))
          Text("Your money, in good company.")
            .font(MiraFont.caption(13)).foregroundStyle(brand.textSecondary)
        }
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(brand.hairline.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Close menu")
      }
      .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 20)

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(spacing: 6) {
            Button {
              session.newConversation()
              dismiss()
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                Text("New chat").font(MiraFont.label(16))
                Spacer()
                Image(systemName: "plus").font(.system(size: 14))
              }
              .padding(.horizontal, 18).frame(minHeight: 52)
              .foregroundStyle(brand.surface)
              .background(brand.ink, in: RoundedRectangle(cornerRadius: 26))
            }
            .accessibilityHint("Saves this conversation and starts a new one")
            Button {
              onProfileStory()
            } label: {
              HStack(spacing: 14) {
                Image(systemName: "person.text.rectangle")
                  .frame(width: 24)
                Text("Profile story").font(MiraFont.body(16))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                  .font(.system(size: 11, weight: .medium))
              }
              .padding(.horizontal, 6)
              .frame(minHeight: 48)
              .contentShape(Rectangle())
            }
            row(.threads)
          }

          VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your money")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                    count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 8) {
              shortcut(.accounts)
              shortcut(.move)
              shortcut(.cards)
            }
            VStack(spacing: 0) {
              row(.activity)
              row(.plan)
              row(.piggyBanks)
              row(.bills)
              row(.contacts)
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            HStack {
              sectionTitle("Your specialists")
              Spacer()
              Button("See all") { onRoute(.specialists) }
                .font(MiraFont.label(13))
                .frame(minHeight: 44)
                .accessibilityLabel("See all specialists")
            }
            ScrollView(.horizontal) {
              HStack(alignment: .top, spacing: 16) {
                ForEach(session.roster) { agent in
                  Button { onSpecialist(agent) } label: {
                    VStack(spacing: 7) {
                      AgentAvatar(agent: agent, size: 48)
                      Text(agent.name).font(MiraFont.caption(12))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: typeSize.isAccessibilitySize ? 160 : 96)
                  }
                  .accessibilityLabel("\(agent.name), \(agent.role)")
                }
              }
              .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
          }
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
      }
      .scrollIndicators(.hidden)

      Divider().overlay(brand.hairline)
      HStack(spacing: 12) {
        Button {
          onSwitchProfile()
        } label: {
          HStack(spacing: 12) {
            UserAvatar(persona: session.persona, size: 38)
            VStack(alignment: .leading, spacing: 3) {
              Text(session.persona.name).font(MiraFont.label(14))
              Text("Switch profile").font(MiraFont.caption(12))
                .foregroundStyle(brand.textSecondary)
            }
            Spacer(minLength: 0)
          }
          .frame(minHeight: 52).contentShape(Rectangle())
        }
        Button { onRoute(.controls) } label: {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 18)).frame(width: 48, height: 48)
            .background(brand.hairline.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Controls")
        .accessibilityHint(HomeRoute.controls.subtitle)
      }
      .padding(.horizontal, 24).padding(.vertical, 12)
    }
    .foregroundStyle(brand.text)
    .buttonStyle(.plain)
    .background(brand.canvas)
    .presentationDragIndicator(.hidden)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(MiraFont.label(13)).foregroundStyle(brand.textSecondary)
      .accessibilityAddTraits(.isHeader)
  }

  private func row(_ destination: HomeRoute) -> some View {
    Button { onRoute(destination) } label: {
      HStack(spacing: 14) {
        Image(systemName: destination.glyph)
          .font(.system(size: 18, weight: .regular)).frame(width: 24)
          .foregroundStyle(brand.textSecondary)
        Text(destination.title).font(MiraFont.body(16))
        Spacer(minLength: 8)
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
          .foregroundStyle(brand.textTertiary)
      }
      .padding(.horizontal, 6).padding(.vertical, 10)
      .frame(minHeight: 48).contentShape(Rectangle())
    }
    .accessibilityHint(destination.subtitle)
  }

  private func shortcut(_ destination: HomeRoute) -> some View {
    Button { onRoute(destination) } label: {
      VStack(alignment: .leading, spacing: 16) {
        Image(systemName: destination.glyph)
          .font(.system(size: 21, weight: .regular))
        Text(destination.title).font(MiraFont.label(13))
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .foregroundStyle(brand.text)
      .background(brand.hairline.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
    }
    .accessibilityHint(destination.subtitle)
  }
}

// MARK: - Card controls

/// The card has no home of its own in the chat shell, so the menu gives it a
/// small one: the real local freeze state and the balances, nothing invented.
struct CardsScreen: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @State private var showingDetails = false

  /// The card as the app holds it: the brand's own, with the live freeze state.
  private var card: CardMock {
    var base = brand.kind == .orion ? CardMock.orion : CardMock.aurea
    base = CardMock(
      id: base.id, nickname: base.nickname, holder: base.holder, pan: base.pan,
      expiry: base.expiry, cvv: base.cvv, network: base.network, kind: base.kind,
      frozen: session.cardFrozen)
    return base
  }

  private var cardFace: some View {
    Button {
      showingDetails = true
    } label: {
      MiraCardFace(card: card, style: faceStyle)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Card details")
  }

  private var faceStyle: MiraCardFace.Style {
    switch brand.kind {
    case .orion: return .orion
    case .aurea: return .aurea(imageName: "aurea-card")
    }
  }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Card", subtitle: "Freeze it, or see the details",
          onClose: { dismiss() })

        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            cardFace
            CardControlsCard()
            CardDetailsButton(card: card, kind: .secondary, onOpen: { showingDetails = true })
            BalanceActionCard()
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(600)
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showingDetails) {
      CardDetailsView(card: card)
    }
  }
}

// MARK: - History

/// Two histories in one place: the decisions Mira recorded, and the transcript
/// itself. The decisions are the important half — they say which specialist
/// answered, what type of action was chosen, and whether a model was involved.
struct ThreadsHistoryView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM · HH:mm"
    return formatter
  }()

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Conversations", subtitle: "Saved on this device",
          onClose: { dismiss() })

        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            Button("New chat") {
              session.newConversation()
              dismiss()
            }
            .buttonStyle(BrandButtonStyle(kind: .primary, fullWidth: false))

            if session.threadsNewestFirst.isEmpty {
              Text("No saved chats yet. Ask Mira something and the conversation will appear here.")
                .font(MiraFont.body(15))
                .foregroundStyle(brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
              VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(session.threadsNewestFirst) { thread in
                  threadRow(thread)
                }
              }
            }

            if !session.actionHistory.isEmpty {
              DisclosureGroup {
                VStack(alignment: .leading, spacing: Space.sm) {
                  ForEach(session.actionHistory) { record in
                    recordRow(record)
                  }
                }
                .padding(.top, Space.sm)
              } label: {
                Text("What Mira recorded")
                  .font(MiraFont.label(15))
                  .foregroundStyle(brand.textSecondary)
              }
              .tint(brand.textTertiary)
            }
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(620)
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
    .navigationBarHidden(true)
  }

  /// One stored conversation. Tapping it saves the current thread and restores
  /// this one; the active thread is marked so it is clear where you are.
  private func threadRow(_ thread: StoredThread) -> some View {
    let isActive = thread.id == session.activeThreadId
    return Button {
      session.selectThread(thread.id)
      dismiss()
    } label: {
      Panel(padding: Space.sm, tint: isActive ? brand.accentTint : nil) {
        HStack(alignment: .top, spacing: Space.sm) {
          Image(systemName: isActive ? "bubble.left.fill" : "bubble.left")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isActive ? brand.accentDeep : brand.textTertiary)
            .frame(width: 30, height: 30)
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Space.xs) {
              Text(thread.title)
                .font(MiraFont.label(15))
                .foregroundStyle(brand.text)
                .lineLimit(1)
              Spacer(minLength: Space.xs)
              Text(recency(thread.updatedAt))
                .font(MiraFont.caption(11))
                .foregroundStyle(brand.textTertiary)
                .layoutPriority(1)
            }
            if let preview = thread.preview {
              Text(preview)
                .font(MiraFont.body(13))
                .foregroundStyle(brand.textSecondary)
                .lineLimit(1)
            }
            if isActive {
              Text("OPEN NOW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(brand.accentDeep)
            }
          }
        }
        .frame(minHeight: 44)
      }
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Delete conversation", role: .destructive) { session.deleteThread(thread.id) }
    }
    .accessibilityLabel(isActive ? "Open \(thread.title), currently open" : "Open \(thread.title)")
  }

  /// A short recency, so the list reads newest-first at a glance.
  private func recency(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
    return ThreadsHistoryView.stamp.string(from: date)
  }

  private func recordRow(_ record: ActionRecord) -> some View {
    Panel(padding: Space.sm) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: Space.xs) {
          Text(record.kind.rawValue.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(brand.textTertiary)
          Spacer(minLength: Space.xs)
          Text(Self.stamp.string(from: record.at))
            .font(MiraFont.caption(11))
            .foregroundStyle(brand.textTertiary)
        }
        Text(record.title)
          .font(MiraFont.label(15))
          .foregroundStyle(brand.text)
        Text(record.detail)
          .font(MiraFont.body(13))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
