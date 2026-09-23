import SwiftUI
import UIKit

// MARK: - Avatar

/// A specialist's mark.
///
/// The generated avatar is used when it is present in the catalog (the names are
/// wired as `agent-aurea-planner`, and so on). Until those images arrive, and
/// whenever one is missing, this falls back to the specialist's SF Symbol. The
/// fallback is a real rendering, not a placeholder to ship.
struct AgentAvatar: View {
  let agent: AgentSpecialist
  var size: CGFloat = 34

  @Environment(\.brand) private var brand

  var body: some View {
    Group {
      if let image = MiraArt.image(named: agent.assetName) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: agent.symbol)
          .font(.system(size: size * 0.42, weight: .medium))
          .foregroundStyle(brand.accentDeep)
      }
    }
    .frame(width: size, height: size)
    .background(brand.accentTint, in: Circle())
    .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
    .clipShape(Circle())
    .accessibilityHidden(true)
  }
}

// MARK: - One turn

struct ChatTurnView: View {
  let turn: ConversationTurn
  /// Whether this turn's chips are live. Chips belong to the last turn of the
  /// flow that owns them, not to the newest turn in the transcript, so an
  /// answer keeps its actions while its subject is still the subject.
  var showsChips: Bool = false

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  var body: some View {
    switch turn.role {
    case .user: userBubble
    case .mira: miraTurn
    }
  }

  private var userBubble: some View {
    HStack {
      Spacer(minLength: Space.xl)
      Text(turn.text)
        .font(MiraFont.body(16))
        .foregroundStyle(brand.text)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(brand.hairline.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .accessibilityLabel("You said: \(turn.text)")
    }
  }

  private var miraTurn: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      if let agent = turn.specialist {
        HStack(spacing: Space.xs) {
          AgentAvatar(agent: agent, size: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text(agent.name)
              .font(MiraFont.label(14))
              .foregroundStyle(brand.text)
          }
        }
      }

      if !cardOwnsQuestion && !taskOwnsResponse {
        if Self.isQuestionTurn(turn) {
          questionText
        } else {
          answerText
        }
      }

      if let card = turn.card {
        VStack(alignment: .leading, spacing: Space.xs) {
          MiraCardFace(card: card, style: cardStyle)
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let caption = turn.cardCaption {
            Text(caption)
              .font(MiraFont.caption(12))
              .foregroundStyle(brand.textTertiary)
          }
        }
        .padding(.top, Space.xxs)
      }

      if let action = turn.action {
        actionCard(action)
      }

      if let receipt = turn.receipt {
        ReceiptCardView(receipt: receipt)
      }

      if showsChips, !turn.chips.isEmpty, turn.flow != "subscriptions" {
        chipRow
      }
    }
  }

  /// An answer reads top-down: its first sentence is the answer and keeps the
  /// body size; what follows is the working, one size and one shade quieter,
  /// so the reply can be taken in at a glance without any chrome.
  private var answerText: some View {
    let parts = Self.firstSentence(of: turn.text)
    return VStack(alignment: .leading, spacing: Space.xxs) {
      Text(parts.lead)
        .font(MiraFont.body(17))
        .foregroundStyle(turn.isError ? brand.textSecondary : brand.text)
        .fixedSize(horizontal: false, vertical: true)

      if let rest = parts.rest {
        Text(rest)
          .font(MiraFont.body(15))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A question looks like one: larger and quieter than an answer, and never
  /// boxed. The person should see that the next move is theirs.
  private var questionText: some View {
    Text(turn.text)
      .font(MiraFont.body(19))
      .foregroundStyle(brand.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// True when the assistant's line is the question its task card is asking.
  /// The card is the question's home; printing the same sentence above it makes
  /// the card look like a footnote to its own question.
  private var cardOwnsQuestion: Bool {
    guard let action = turn.action, action.kind == .agentTask else { return false }
    return AgentTaskCard.carriesQuestion(session.task(for: action), spoken: turn.text)
  }

  private var taskOwnsResponse: Bool {
    guard turn.action?.kind == .agentTask else { return false }
    let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return text.hasPrefix("on it") || text.hasPrefix("i’ll come back")
      || text.hasPrefix("i'll come back")
  }

  /// The card face matches the app it lives in.
  private var cardStyle: MiraCardFace.Style {
    brand.kind == .orion ? .orion : .aurea(imageName: "aurea-card")
  }

  /// Chips: suggestions the person can tap. A tap sends the chip as their own
  /// message, so a chip can never do more than typing the same words would.
  /// Three at most, one line each: a row of chips is an offer, not a menu.
  private var chipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Space.xs) {
        ForEach(turn.chips.prefix(3), id: \.self) { chip in
          Button {
            Task { await session.sendChat(chip) }
          } label: {
            Text(chip)
              .font(MiraFont.label(13))
              .foregroundStyle(brand.text)
              .lineLimit(1)
              .padding(.horizontal, 13)
              .padding(.vertical, 8)
              .background(Capsule().fill(brand.surface))
              .overlay(Capsule().strokeBorder(brand.textTertiary.opacity(0.28), lineWidth: 1))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Suggest: \(chip)")
        }
      }
      .padding(.vertical, 1)
    }
    .padding(.top, Space.xxs)
  }

  @ViewBuilder
  private func actionCard(_ action: AgentAction) -> some View {
    switch action.kind {
    case .proposeTransfer:
      TransferProposalCard(turnId: turn.id, action: action)
    case .askTransferDetails:
      TransferDetailsCard(action: action)
    case .showBalance:
      BalanceActionCard()
    case .showBudget:
      BudgetActionCard()
    case .proposeBudgetUpdate:
      BudgetProposalCard(turnId: turn.id, action: action)
    case .openCardControls:
      CardControlsCard()
    case .openReceive:
      ReceiveActionCard()
    case .requirementsFlow:
      RequirementsCard(action: action)
    case .agentTask:
      AgentTaskCard(action: action)
    case .transferReceipt:
      ReceiptCard(action: action)
    case .reply:
      EmptyView()
    }
  }

  // MARK: - Reading a turn
  //
  // The transcript's two text rules are pure functions of a turn, so the shape
  // of a reply can be proven in tests rather than only seen on a screen.

  /// A Mira turn is a question when it is asking the person something: short,
  /// a question mark at the end, and nothing attached. A card or a typed action
  /// already has a shape of its own, and an error is a statement.
  static func isQuestionTurn(_ turn: ConversationTurn) -> Bool {
    guard turn.role == .mira, !turn.isError else { return false }
    if let action = turn.action, action.kind != .reply { return false }
    guard turn.card == nil, turn.receipt == nil else { return false }
    let clean = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.hasSuffix("?"), !clean.contains("\n") else { return false }
    return clean.count <= 160
  }

  /// The first sentence of a reply, and whatever follows it when there is more
  /// than one. Only a full stop, exclamation or question mark followed by a
  /// space or the end of the text ends a sentence, so a decimal such as
  /// "USD 269.70" stays in one piece.
  static func firstSentence(of text: String) -> (lead: String, rest: String?) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return (clean, nil) }

    var index = clean.startIndex
    while index < clean.endIndex {
      let character = clean[index]
      if character == "." || character == "!" || character == "?" {
        let next = clean.index(after: index)
        if next == clean.endIndex || clean[next].isWhitespace {
          let lead = String(clean[clean.startIndex...index])
          let rest = String(clean[next...]).trimmingCharacters(in: .whitespacesAndNewlines)
          return (lead, rest.isEmpty ? nil : rest)
        }
      }
      index = clean.index(after: index)
    }
    return (clean, nil)
  }
}

// MARK: - Shared card chrome

/// One container for every card inside the chat, so they read as one system.
struct ChatCard<Content: View>: View {
  var footer: String? = nil
  @ViewBuilder var content: () -> Content

  @Environment(\.brand) private var brand

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      content()
      if let footer {
        Text(footer)
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        .strokeBorder(brand.hairline, lineWidth: 1)
    }
  }
}

private struct CardHeadline: View {
  let title: String
  var detail: String? = nil

  @Environment(\.brand) private var brand

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(MiraFont.title(17))
        .foregroundStyle(brand.text)
      if let detail {
        Text(detail)
          .font(MiraFont.body(14))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Transfer proposal

struct TransferProposalCard: View {
  let turnId: UUID
  let action: AgentAction

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  private var state: TransferProposalState? { session.transferProposalStates[turnId] }

  var body: some View {
    ChatCard(footer: "Prepared by Mira. Sent only when you approve.") {
      CardHeadline(
        title: "Transfer \(action.amount?.display ?? "")",
        detail: "From \(action.from ?? session.appName) to \(action.to ?? "—").")
      Rule()
      FieldLine(label: "Asset", value: action.assetCode ?? "—", mono: true)
      FieldLine(label: "To", value: action.to ?? "—")

      switch state {
      case .proposed, .none:
        HStack(spacing: Space.xs) {
          Button("Confirm") { Task { await session.confirmTransfer(for: turnId) } }
            .buttonStyle(BrandButtonStyle(kind: .gold))
          Button("Not now") { session.cancelTransfer(for: turnId) }
            .buttonStyle(BrandButtonStyle(kind: .quiet))
        }
      case .sending:
        HStack(spacing: Space.xs) {
          MiraDot(size: 8, pulsing: true)
          Text("Sending…")
            .font(MiraFont.body(14))
            .foregroundStyle(brand.textSecondary)
        }
      case .settled(let receipt):
        Label("Settled · \(receipt)", systemImage: "checkmark.circle.fill")
          .font(MiraFont.label(14))
          .foregroundStyle(MiraColor.settled)
      case .failed(let message):
        Label(message, systemImage: "xmark.circle.fill")
          .font(MiraFont.body(14))
          .foregroundStyle(MiraColor.failed)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct TransferDetailsCard: View {
  let action: AgentAction

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  private var missingText: String {
    let missing = action.missing.isEmpty ? ["amount and currency"] : action.missing
    return missing.joined(separator: ", ")
  }

  /// The recipients this build can actually address. An already-resolved
  /// recipient is shown alone; otherwise the supported pair is offered. A
  /// recipient is never invented.
  private var recipients: [String] {
    if let to = action.to, !to.isEmpty { return [to] }
    if !action.knownRecipients.isEmpty { return action.knownRecipients }
    return [session.otherAppName]
  }

  /// An exact instruction built from the action's own amount. When there is no
  /// amount yet, the offer asks for one rather than inventing a figure.
  private func message(for recipient: String) -> String {
    if let amount = action.amount {
      return "Send \(amount.currency.code) \(MoneyFormatter.amount(amount)) to \(recipient)"
    }
    return "Send money to \(recipient)"
  }

  var body: some View {
    ChatCard(
      footer: "Enter an amount and currency."
    ) {
      CardHeadline(
        title: "I need the exact details",
        detail: "Missing: \(missingText).")
      VStack(alignment: .leading, spacing: Space.xs) {
        ForEach(recipients, id: \.self) { name in
          Button(message(for: name)) {
            Task { await session.sendChat(message(for: name)) }
          }
          .buttonStyle(BrandButtonStyle(kind: .secondary))
        }
      }
    }
  }
}

// MARK: - Balance and budget

struct BalanceActionCard: View {
  @Environment(MiraSession.self) private var session

  var body: some View {
    let holdings = session.ledger.holdings().filter { $0.amount.minorUnits != 0 }
    ChatCard(footer: "Your balances.") {
      CardHeadline(title: "Where your money is")
      Rule()
      ForEach(holdings, id: \.asset.code) { item in
        FieldLine(label: item.asset.name, value: item.amount.display, mono: true)
      }
      if session.ledger.pendingUSD.minorUnits > 0 {
        FieldLine(label: "Pending (not spendable)", value: session.ledger.pendingUSD.display)
      }
    }
  }
}

struct BudgetActionCard: View {
  @Environment(MiraSession.self) private var session
  @State private var showEditor = false

  var body: some View {
    ChatCard(footer: "Your plan.") {
      CardHeadline(title: "This week", detail: session.plan.status.headline)
      Rule()
      FieldLine(
        label: "Left this week", value: session.currentWeekRemaining.display, strong: true)
      FieldLine(label: "Weekly budget", value: session.plan.weeklyBudgetMoney.display, mono: true)
      Button("Adjust weekly budget") { showEditor = true }
        .buttonStyle(BrandButtonStyle(kind: .secondary))
    }
    .sheet(isPresented: $showEditor) { BudgetEditorSheet() }
  }
}

struct BudgetProposalCard: View {
  let turnId: UUID
  let action: AgentAction
  @State private var applied = false

  @Environment(MiraSession.self) private var session

  var body: some View {
    let amount = action.amount ?? Money(minorUnits: 0, currency: .usd)
    ChatCard(footer: "Nothing changes until you approve it.") {
      CardHeadline(
        title: "Set the weekly budget to \(amount.display)?",
        detail: "This changes the discretionary envelope, not the reserve or your bills.")
      if applied {
        Label("Applied · \(amount.display)", systemImage: "checkmark.circle.fill")
          .font(MiraFont.label(14))
          .foregroundStyle(MiraColor.settled)
      } else {
        HStack(spacing: Space.xs) {
          Button("Apply") {
            session.applyBudgetUpdate(amountMinor: amount.minorUnits)
            applied = true
          }
          .buttonStyle(BrandButtonStyle(kind: .gold))
          Button("Not now") { applied = true }
            .buttonStyle(BrandButtonStyle(kind: .quiet))
        }
      }
    }
  }
}

/// A small, local editor for the discretionary budget.
struct BudgetEditorSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @State private var text: String = ""

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: Space.lg) {
        Text("Weekly discretionary budget")
          .screenTitle(22)
          .foregroundStyle(brand.text)
        Text("Bills and the reserve are set in Plan. This only changes what is free to spend each week.")
          .font(MiraFont.body(15))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: Space.xs) {
          Text("USD")
            .font(MiraFont.mono(15))
            .foregroundStyle(brand.textSecondary)
          TextField("300.00", text: $text)
            .keyboardType(.decimalPad)
            .font(MiraFont.figure(20))
            .padding(Space.sm)
            .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium))
            .overlay {
              RoundedRectangle(cornerRadius: Radius.medium)
                .strokeBorder(brand.hairline, lineWidth: 1)
            }
        }

        Button("Apply") {
          let value = Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) ?? 0
          let amount = Money(majorUnits: value, currency: .usd)
          session.applyBudgetUpdate(amountMinor: amount.minorUnits)
          dismiss()
        }
        .buttonStyle(BrandButtonStyle(kind: .gold))
        .disabled(Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) == nil)

        Spacer()
      }
      .padding(Space.gutter)
      .background(brand.canvas.ignoresSafeArea())
      .navigationTitle("Budget")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { text = MoneyFormatter.amount(session.plan.discretionaryBudget) }
    }
  }
}

// MARK: - Card controls

struct CardControlsCard: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  /// The card as the chat knows it: the brand's own, with the live freeze state.
  private var card: CardMock {
    var base = brand.kind == .orion ? CardMock.orion : CardMock.aurea
    base = CardMock(
      id: base.id, nickname: base.nickname, holder: base.holder, pan: base.pan,
      expiry: base.expiry, cvv: base.cvv, network: base.network, kind: base.kind,
      frozen: session.cardFrozen)
    return base
  }

  var body: some View {
    ChatCard(footer: "Mira keeps your card settings on this device and applies them at once.") {
      CardHeadline(
        title: session.cardFrozen ? "Your card is frozen" : "Your card is active",
        detail: session.cardFrozen
          ? "New charges are declined while it stays frozen."
          : "You can freeze it instantly, and unfreeze it just as fast.")
      Button(session.cardFrozen ? "Unfreeze card" : "Freeze card") {
        session.toggleCardFreeze()
      }
      .buttonStyle(BrandButtonStyle(kind: session.cardFrozen ? .secondary : .gold))

      CardDetailsButton(card: card)

      // Merchants blocked at this card: a bank lever a cancellation form
      // cannot pull.
      let blocked = session.localDirectory.blockedMerchants(on: card.last4)
      if !blocked.isEmpty {
        Text(
          blocked.count == 1
            ? "1 merchant blocked: \(blocked[0])."
            : "\(blocked.count) merchants blocked: \(blocked.joined(separator: ", "))."
        )
        .font(MiraFont.caption(12))
        .foregroundStyle(brand.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Receive

struct ReceiveActionCard: View {
  @Environment(MiraSession.self) private var session

  var body: some View {
    ChatCard(footer: "Share these and Mira will match what arrives.") {
      CardHeadline(title: "Receiving into \(session.appName)")
      Rule()
      FieldLine(label: "Identity", value: session.appName, mono: true)
      FieldLine(label: "Method", value: "Mira transfer", mono: true)
      Text("Sent to your identity by name.")
        .font(MiraFont.body(14))
        .foregroundStyle(brandTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var brandTextSecondary: Color { MiraColor.textSecondary }
}

// MARK: - Requirements (no provider connected)

struct RequirementsCard: View {
  let action: AgentAction

  @Environment(\.brand) private var brand

  private var isBill: Bool { action.topic == "bill" }

  private var heading: String {
    switch action.topic {
    case "travel": return "Planning a trip"
    case "shopping": return "Buying something"
    case "bill": return "Paying a bill"
    default: return "What I would need"
    }
  }

  private var detail: String {
    isBill
      ? "Tell Mira the bill and it will keep the details, watch the date and bring it to you in time."
      : "Tell Mira what you are after and it will research the options for you."
  }

  private var footer: String {
    isBill
      ? "Mira brings the bill to you when it is due. You approve every payment."
      : "Mira comes back with what it found, with the sources it used."
  }

  private var requirements: [String] {
    if !action.requirements.isEmpty { return action.requirements }
    return [
      "Exactly what you want, with a link or reference",
      "Who you would buy it from",
      "The maximum you are willing to pay, all in",
      "The currency you would pay in",
    ]
  }

  var body: some View {
    ChatCard(footer: footer) {
      CardHeadline(title: heading, detail: detail)
      if let amount = action.amount {
        Rule()
        FieldLine(label: "Amount you mentioned", value: amount.display, mono: true)
      }
      Rule()
      ForEach(requirements, id: \.self) { item in
        HStack(alignment: .top, spacing: Space.xs) {
          Image(systemName: "square")
            .font(.system(size: 12))
            .foregroundStyle(brand.textTertiary)
            .padding(.top, 2)
          Text(item)
            .font(MiraFont.body(14))
            .foregroundStyle(brand.text)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

// MARK: - Receipt

struct ReceiptCard: View {
  let action: AgentAction

  @Environment(\.brand) private var brand

  var body: some View {
    ChatCard(footer: "Kept in your activity.") {
      HStack(spacing: Space.xs) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(MiraColor.settled)
        CardHeadline(title: "Receipt", detail: action.receiptLine)
      }
      Rule()
      FieldLine(label: "From", value: action.from ?? "—")
      FieldLine(label: "To", value: action.to ?? "—")
      if let amount = action.amount {
        FieldLine(label: "Amount", value: amount.display, mono: true)
      }
      if let id = action.transferId {
        FieldLine(label: "Reference", value: id, mono: true)
      }
    }
  }
}
