import SwiftUI

// MARK: - Accounts

/// Betelgeuse. The anchor of the figure, and of the account.
struct OrionAccounts: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.md) {
        VStack(alignment: .leading, spacing: Space.xxs) {
          Text("Available")
            .font(.system(size: 13))
            .foregroundStyle(brand.textSecondary)
          PaperNumber(value: MoneyFormatter.amount(session.clearedUSD), size: 54)
          Text("USD equivalent, spendable now")
            .font(.system(size: 12))
            .foregroundStyle(brand.textTertiary)
        }

        holdings
        recent

        HStack(spacing: Space.xs) {
          Button("Receive") { session.requestTab(.move) }
            .buttonStyle(PaperButtonStyle(kind: .outlined))
          Button("Send") { session.requestTab(.move) }
            .buttonStyle(PaperButtonStyle(kind: .filled))
        }
      }
      .padding(.horizontal, Space.gutter)
      .readableWidth(600)
      .padding(.bottom, Space.xxl)
    }
    .scrollIndicators(.hidden)
  }

  private var holdings: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      PaperLabel("Balances")
      PaperPanel(padding: Space.xs) {
        VStack(spacing: 0) {
          ForEach(Array(session.ledger.holdings().enumerated()), id: \.element.asset.code) { index, holding in
            HStack(spacing: Space.sm) {
              CurrencyMark(asset: holding.asset, size: 32)

              VStack(alignment: .leading, spacing: 1) {
                Text(holding.asset.name)
                  .font(.system(size: 14, weight: .medium))
                  .foregroundStyle(brand.text)
                Text(holding.asset.kind == .stablecoin ? "Stablecoin · 6 decimals" : holding.asset.code)
                  .font(.system(size: 10.5))
                  .foregroundStyle(brand.textTertiary)
              }
              Spacer(minLength: Space.xs)
              Text(MoneyFormatter.amount(holding.amount))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(holding.amount.minorUnits == 0 ? brand.textTertiary : brand.text)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 10)

            if index != session.ledger.holdings().count - 1 {
              Rectangle().fill(brand.hairline).frame(height: 1)
            }
          }
        }
      }
    }
  }

  private var recent: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      PaperLabel("Recent")
      PaperPanel(padding: Space.xs) {
        VStack(spacing: 0) {
          ForEach(Array(session.ledger.newestFirst.prefix(6).enumerated()), id: \.element.id) { index, entry in
            HStack(spacing: Space.sm) {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.memo)
                  .font(.system(size: 13.5))
                  .foregroundStyle(brand.text)
                  .multilineTextAlignment(.leading)
                Text(entry.date.formatted(.dateTime.day().month(.abbreviated)))
                  .font(.system(size: 10.5))
                  .foregroundStyle(brand.textTertiary)
              }
              Spacer(minLength: Space.xs)
              if let movement = entry.postings.first(where: { $0.accountId == "usd.cleared" })?.amount {
                Text(movement.signedDisplay)
                  .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                  .foregroundStyle(movement.isNegative ? brand.textSecondary : MiraColor.settled)
              }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 9)

            if index != min(6, session.ledger.newestFirst.count) - 1 {
              Rectangle().fill(brand.hairline).frame(height: 1)
            }
          }
        }
      }
    }
  }
}

// MARK: - Move

/// Alnilam, the middle of the belt. Where things cross.
struct OrionMove: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var from: Asset = .usd
  @State private var to: Asset = .usdc
  @State private var amount: Double = 500
  @State private var quote: SwapQuote?
  @State private var error: String?
  @State private var confirm: TransferDraft?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.md) {
        VStack(alignment: .leading, spacing: Space.xxs) {
          Text("You move")
            .font(.system(size: 13))
            .foregroundStyle(brand.textSecondary)
          PaperNumber(value: "\(from.code) \(Int(amount))", size: 42)
        }

        PaperPanel {
          VStack(spacing: Space.sm) {
            picker("From", selection: $from)
            Rectangle().fill(brand.hairline).frame(height: 1)
            picker("To", selection: $to)
            Rectangle().fill(brand.hairline).frame(height: 1)
            Slider(value: $amount, in: 10...4000, step: 10)
              .tint(brand.text)
          }
        }

        if let quote {
          PaperPanel {
            VStack(spacing: Space.sm) {
              row("Rate", quote.rateLabel)
              row("Fee", quote.fee.display)
              Rectangle().fill(brand.hairline).frame(height: 1)
              row("They receive", quote.toAmount.display, strong: true)
            }
          }
        }

        if let error {
          Text(error).font(.system(size: 13)).foregroundStyle(MiraColor.failed)
        }

        VStack(spacing: Space.xs) {
          if let quote {
            Button("Move \(quote.fromAmount.display)") { execute(quote) }
              .buttonStyle(PaperButtonStyle(kind: .filled))
          } else {
            Button("Get a rate") { quoteIt() }
              .buttonStyle(PaperButtonStyle(kind: .filled))
          }
        }

        sendTo
      }
      .padding(.horizontal, Space.gutter)
      .readableWidth(600)
      .padding(.bottom, Space.xxl)
    }
    .scrollIndicators(.hidden)
    .onChange(of: from) { _, _ in quote = nil }
    .onChange(of: to) { _, _ in quote = nil }
    .sheet(item: $confirm) { draft in TransferConfirmSheet(draft: draft) }
  }

  private func picker(_ label: String, selection: Binding<Asset>) -> some View {
    HStack(spacing: Space.sm) {
      CurrencyMark(asset: selection.wrappedValue, size: 32)
      Text(label).font(.system(size: 13)).foregroundStyle(brand.textSecondary)
      Spacer()
      Picker(label, selection: selection) {
        ForEach(Asset.all) { asset in
          Text("\(asset.code) · \(asset.name)").tag(asset)
        }
      }
      .pickerStyle(.menu)
      .tint(brand.text)
    }
  }

  private func row(_ label: String, _ value: String, strong: Bool = false) -> some View {
    HStack {
      Text(label).font(.system(size: 13)).foregroundStyle(brand.textSecondary)
      Spacer()
      Text(value)
        .font(.system(size: strong ? 16 : 14, weight: strong ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(brand.text)
    }
  }

  /// Stablecoin destinations, with the Pix rail alongside them: both are just
  /// ways to get money to someone.
  private var sendTo: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      PaperLabel("Send to")
      PaperPanel(padding: Space.xs) {
        VStack(spacing: 0) {
          pixRow
          Rectangle().fill(brand.hairline).frame(height: 1)
          ForEach(Array(AddressBook.all.enumerated()), id: \.element.value) { index, address in
            addressRow(address)
            if index != AddressBook.all.count - 1 {
              Rectangle().fill(brand.hairline).frame(height: 1)
            }
          }
        }
      }
    }
  }

  private var pixRow: some View {
    Button {
      session.requestTab(.move)
    } label: {
      HStack(spacing: Space.sm) {
        PixMark(size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text("Pix")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(brand.text)
          Text("Brazilian Real · instant")
            .font(.system(size: 10.5))
            .foregroundStyle(brand.textTertiary)
        }
        Spacer(minLength: Space.xs)
        Text("30.30 USD all-in")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(brand.textSecondary)
      }
      .padding(.horizontal, Space.sm)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func addressRow(_ address: ChainAddress) -> some View {
    Button {
      // Only stablecoins can go to a chain address.
      from = .usdc
      confirm = TransferDraft(asset: .usdc, to: address, amount: Money(majorUnits: 100, currency: .usdc), fee: Money(minorUnits: 120_000, currency: .usdc))
    } label: {
      HStack(spacing: Space.sm) {
        ZStack {
          Circle().fill(brand.accentTint)
          Image(systemName: "link")
            .font(.system(size: 12))
            .foregroundStyle(brand.text)
        }
        .frame(width: 32, height: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(address.label ?? address.short)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(brand.text)
          Text("\(address.network.displayName) · \(address.short)")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(brand.textTertiary)
        }
        Spacer(minLength: Space.xs)
        Image(systemName: "arrow.up.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(brand.textTertiary)
      }
      .padding(.horizontal, Space.sm)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func quoteIt() {
    error = nil
    do {
      quote = try SimulatedSwapProvider.demo.quote(
        from: from, to: to, amount: Money(majorUnits: Decimal(amount), currency: from))
    } catch {
      self.error = "That pair has no rate in this build."
    }
  }

  private func execute(_ quote: SwapQuote) {
    error = nil
    do {
      if try session.ledger.postSwap(
        quote,
        idempotencyKey: "ui-swap-\(quote.id.uuidString)",
        memo: "Swap \(quote.from.code) to \(quote.to.code)",
        at: Date()
      ) {
        session.recordSwap(quote)
        self.quote = nil
      }
    } catch {
      self.error = "The ledger rejected that swap."
    }
  }
}

// MARK: - Mira

/// The sword, next to the nebula. Where Mira is.
struct OrionMira: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          // The assistant, centred and given room. The mark is alive: a ring
          // turning with a bead orbiting it, always in motion.
          VStack(spacing: Space.sm) {
            ZStack {
              OrbitRing(size: 72, color: brand.text, lineWidth: 1, period: 11, highlight: 0.24)
              OrbitRing(size: 48, color: brand.text, lineWidth: 0.7, period: 7, highlight: 0.3)
              OrbitingDot(pathSize: 72, dotSize: 6, color: brand.text, period: 8)
              Circle().fill(brand.text).frame(width: 13, height: 13)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 3) {
              Text("Ask about your money")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(brand.text)
              Text(session.isWorking ? "Reading your account" : "Grounded in your ledger")
                .font(.system(size: 12.5))
                .foregroundStyle(brand.textTertiary)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.top, Space.sm)
          .padding(.bottom, Space.md)

          if session.conversation.isEmpty { starters }

          ForEach(session.conversation) { turn in
            if turn.role == .user {
              HStack {
                Spacer(minLength: Space.xl)
                Text(turn.text)
                  .font(.system(size: 14))
                  .foregroundStyle(brand.canvas)
                  .padding(.horizontal, Space.md)
                  .padding(.vertical, Space.xs)
                  .background(brand.text, in: Capsule())
              }
            } else {
              Text(turn.text)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(brand.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          if let reply = session.lastAgentReply { grounded(reply) }
          if let message = session.lastAgentError { failure(message) }
          if session.isWorking { ChartingIndicator() }

          if session.conversation.isEmpty {
            // The lower half is where the explanation goes. Saying plainly what
            // the assistant can and cannot do is more useful than blancmange.
            PaperPanel {
              VStack(alignment: .leading, spacing: Space.sm) {
                PaperLabel("What it can do")
                ForEach(canDo, id: \.self) { line in
                  HStack(alignment: .top, spacing: Space.xs) {
                    Circle().fill(brand.text.opacity(0.5))
                      .frame(width: 4, height: 4).padding(.top, 6)
                    Text(line)
                      .font(.system(size: 13))
                      .foregroundStyle(brand.textSecondary)
                      .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                  }
                }
                Rectangle().fill(brand.hairline).frame(height: 1).padding(.vertical, 2)
                PaperLabel("What it cannot")
                ForEach(cannotDo, id: \.self) { line in
                  HStack(alignment: .top, spacing: Space.xs) {
                    Circle().fill(brand.text.opacity(0.22))
                      .frame(width: 4, height: 4).padding(.top, 6)
                    Text(line)
                      .font(.system(size: 13))
                      .foregroundStyle(brand.textTertiary)
                      .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth(600)
        .padding(.vertical, Space.sm)
      }
      .scrollIndicators(.hidden)

      composer
    }
  }

  private let canDo = [
    "Read your real balances, rate and transactions.",
    "Answer with figures taken from the ledger, and show which.",
    "Flag what looks wrong: a duplicate charge, an odd fee.",
    "Propose one action, as a card you approve.",
  ]

  private let cannotDo = [
    "Move money, or authorise a payment.",
    "Change a limit or a permission.",
    "Decide eligibility.",
    "Invent a number.",
  ]

  private var starters: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      PaperLabel("Try one")
      ForEach(
        [
          "Did anything unusual happen this week?",
          "How much can I spend without touching the reserve?",
          "How much do I hold in stablecoins?",
        ], id: \.self
      ) { text in
        Button {
          Task { await session.askAgent(text) }
        } label: {
          HStack {
            Text(text)
              .font(.system(size: 14))
              .foregroundStyle(brand.text)
              .multilineTextAlignment(.leading)
            Spacer(minLength: Space.xs)
            Image(systemName: "arrow.up.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(brand.textTertiary)
          }
          .padding(.horizontal, Space.md)
          .padding(.vertical, 15)
          .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
              .strokeBorder(brand.hairline, lineWidth: 1)
          }
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private func grounded(_ reply: AgentReply) -> some View {
    if !reply.citations.isEmpty || !reply.flags.isEmpty {
      PaperPanel {
        VStack(alignment: .leading, spacing: Space.sm) {
          ForEach(reply.flags) { flag in
            HStack(alignment: .top, spacing: Space.xs) {
              Circle()
                .fill(flag.severity == .warn ? MiraColor.pending : brand.text.opacity(0.4))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
              Text(flag.text)
                .font(.system(size: 13.5))
                .foregroundStyle(brand.text)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
          }
          if !reply.citations.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              ForEach(reply.citations, id: \.self) { citation in
                Text(citation)
                  .font(.system(size: 11.5))
                  .foregroundStyle(brand.textTertiary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(.leading, 13)
          }
        }
      }
    }
  }

  private func failure(_ message: String) -> some View {
    Text(message)
      .font(.system(size: 13))
      .foregroundStyle(MiraColor.failed)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var composer: some View {
    HStack(spacing: Space.xs) {
      TextField("Ask", text: $draft, axis: .vertical)
        .font(.system(size: 15))
        .lineLimit(1...4)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(brand.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(brand.hairline, lineWidth: 1) }
        .onSubmit(send)

      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(brand.canvas)
          .frame(width: 42, height: 42)
          .background(brand.text, in: Circle())
      }
      .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.isWorking)
      .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
    }
    .padding(.horizontal, Space.gutter)
    .readableWidth(600)
    .padding(.vertical, Space.sm)
    .background(brand.canvas)
    .overlay(alignment: .top) { Rectangle().fill(brand.hairline).frame(height: 1) }
  }

  private func send() {
    let text = draft
    draft = ""
    Task { await session.askAgent(text) }
  }
}

// MARK: - Working state

/// What Orion shows while the model is thinking.
///
/// A small constellation draws itself and holds, the way a plotter lays down
/// stars: the field is being read. Not a spinner, and not the word "Thinking".
struct ChartingIndicator: View {
  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase: Double = 0

  private let nodes: [CGPoint] = [
    CGPoint(x: 0.10, y: 0.30), CGPoint(x: 0.34, y: 0.66),
    CGPoint(x: 0.58, y: 0.56), CGPoint(x: 0.82, y: 0.20),
  ]
  private let edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3)]

  var body: some View {
    HStack(spacing: Space.sm) {
      Canvas { context, size in
        for (a, b) in edges {
          let p1 = nodes[a], p2 = nodes[b]
          let start = Double(a) * 0.24
          let progress = min(max((phase - start) / 0.24, 0), 1)
          guard progress > 0 else { continue }
          var path = Path()
          path.move(to: CGPoint(x: p1.x * size.width, y: p1.y * size.height))
          path.addLine(to: CGPoint(
            x: (p1.x + (p2.x - p1.x) * progress) * size.width,
            y: (p1.y + (p2.y - p1.y) * progress) * size.height))
          context.stroke(
            path,
            with: .color(brand.text.opacity(0.45)),
            style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
        for (index, node) in nodes.enumerated() {
          let lit = phase >= Double(index) * 0.24
          context.fill(
            Path(ellipseIn: CGRect(x: node.x * size.width - 2, y: node.y * size.height - 2, width: 4, height: 4)),
            with: .color(brand.text.opacity(lit ? 0.9 : 0.16)))
        }
      }
      .frame(width: 44, height: 22)

      Text("Reading the sky")
        .font(.system(size: 13))
        .foregroundStyle(brand.textSecondary)
    }
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { phase = 1.2 }
    }
  }
}

// MARK: - You

/// Rigel. The brightest star in the figure, and the screen about you.
struct OrionYou: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @AppStorage("mira.onboarded") private var hasOnboarded = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.md) {
        cardStack
        controls
        demo
        Button("Replay onboarding") { hasOnboarded = false }
          .buttonStyle(PaperButtonStyle(kind: .outlined))
      }
      .padding(.horizontal, Space.gutter)
      .readableWidth(600)
      .padding(.bottom, Space.xxl)
    }
    .scrollIndicators(.hidden)
  }

  private var cardStack: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      PaperLabel("Cards")
      MiraCardFace(
        card: CardMock(
          id: CardMock.orion.id, nickname: CardMock.orion.nickname,
          holder: CardMock.orion.holder, pan: CardMock.orion.pan,
          expiry: CardMock.orion.expiry, cvv: CardMock.orion.cvv,
          network: CardMock.orion.network, kind: CardMock.orion.kind,
          frozen: session.cardFrozen),
        style: .orion
      )
      MiraCardFace(card: CardMock.aureaVirtual, style: .orion)
        .opacity(0.92)
    }
  }

  private var controls: some View {
    PaperPanel {
      VStack(spacing: Space.sm) {
        Toggle(isOn: Binding(get: { session.cardFrozen }, set: { session.setCardFrozen($0) })) {
          Text("Freeze card").font(.system(size: 15)).foregroundStyle(brand.text)
        }
        .tint(brand.text)
        Rectangle().fill(brand.hairline).frame(height: 1)
        Toggle(isOn: Binding(get: { session.controls.assistantEnabled }, set: { session.setAssistantEnabled($0) })) {
          Text("Mira").font(.system(size: 15)).foregroundStyle(brand.text)
        }
        .tint(brand.text)
      }
    }
  }

  private var demo: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      PaperLabel("Mira controls")
      PaperPanel {
        VStack(spacing: Space.xs) {
          Button("Receive a deposit") { session.simulatePendingDeposit() }
            .buttonStyle(PaperButtonStyle(kind: .outlined))
          Button("Clear the deposit") { session.clearPendingDeposit() }
            .buttonStyle(PaperButtonStyle(kind: .outlined))
          Button("Let the quote expire") { session.expireActiveQuote() }
            .buttonStyle(PaperButtonStyle(kind: .outlined))
          Button("Receive 100 USDC from Mira Aurea") { simulateIncomingTransfer() }
            .buttonStyle(PaperButtonStyle(kind: .outlined))
          Button("Send 100 USDC to Mira Aurea") { sendToAurea() }
            .buttonStyle(PaperButtonStyle(kind: .outlined))
        }
      }
    }
  }

  /// The outbound half of the cross-app demo: move real value out of this app's
  /// ledger and announce it, so the other app books the matching inflow.
  private func sendToAurea() {
    Task {
      await session.sendToOtherApp(
        asset: .usdc, amount: Money(minorUnits: 100_000_000, currency: .usdc))
    }
  }

  private func simulateIncomingTransfer() {
    // The other end of the cross-app demo: this is what lands when Aurea sends.
    session.receiveExternalTransfer(
      asset: .usdc,
      amount: Money(minorUnits: 100_000_000, currency: .usdc),
      from: "Mira Aurea"
    )
  }
}
