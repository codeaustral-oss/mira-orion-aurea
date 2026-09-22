import SwiftUI

/// Move Money.
///
/// The printed-plate movement screen. One figure at the top — what is being
/// moved — then where it comes from, where it goes and what it costs, then the
/// people and rails it can reach. The payment flow that does the actual work
/// (review, quote, consent) is untouched and takes over the moment a draft
/// exists; this screen is the door to it.
struct AureaMove: View {
  @Environment(MiraSession.self) private var session

  var body: some View {
    // A live draft owns the screen until it is settled or discarded: that is
    // the transaction in front of you, and the hub is where you start another.
    if session.activePayment != nil {
      MoveView()
    } else {
      AureaMoveHub()
    }
  }
}

struct AureaMoveHub: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var from: Asset = .usd
  @State private var to: Asset = .usdc
  @State private var amount: Double = 500
  @State private var quote: SwapQuote?
  @State private var error: String?
  @State private var confirm: TransferDraft?
  @State private var pasted = ""
  @State private var showProfile = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.lg) {
        header
        heading
        movement
        quoteLines
        action
        destinations
        requests
        closing
      }
      .padding(.horizontal, Space.gutter)
      .readableWidth(620)
      .padding(.bottom, Space.xxl)
    }
    .scrollIndicators(.hidden)
    .onChange(of: from) { _, _ in quote = nil }
    .onChange(of: to) { _, _ in quote = nil }
    .onChange(of: amount) { _, _ in quote = nil }
    .sheet(isPresented: $showProfile) { AureaProfile() }
    .sheet(item: $confirm) { draft in TransferConfirmSheet(draft: draft) }
  }

  // MARK: Chrome

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Mira")
          .font(.system(size: 27, weight: .regular, design: .serif))
          .tracking(0.4)
          .foregroundStyle(brand.text)
        Text("LOOKING AFTER YOU.")
          .font(.system(size: 9, weight: .medium))
          .tracking(3.0)
          .foregroundStyle(brand.textTertiary)
      }
      Spacer()
      Button { showProfile = true } label: {
        ZStack {
          OrbitRing(size: 52, color: brand.accent, lineWidth: 1, period: 14, highlight: 0.22)
          Circle()
            .fill(brand.surface)
            .frame(width: 38, height: 38)
            .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
          Image(systemName: "person")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(brand.text)
        }
        .frame(width: 52, height: 52)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Profile")
    }
    .padding(.top, Space.xs)
  }

  private var heading: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
      Text("Move Money")
        .font(.system(size: 44, weight: .regular, design: .serif))
        .tracking(0.2)
        .foregroundStyle(brand.text)
        .minimumScaleFactor(0.6)
        .lineLimit(1)

      Spacer(minLength: 0)

      VStack(alignment: .trailing, spacing: 3) {
        ForEach(brand.kicker, id: \.self) { word in
          Text(word.uppercased())
            .font(.system(size: 8, weight: .medium))
            .tracking(2.4)
            .foregroundStyle(brand.textTertiary)
        }
        Rectangle()
          .fill(brand.accent)
          .frame(width: 34, height: 1)
          .padding(.top, 2)
      }
      .padding(.bottom, 2)
    }
    .padding(.top, Space.xs)
  }

  // MARK: The movement

  /// The figure, then the two ends of it, then the size. Read top to bottom it
  /// answers what, where from, where to, how much.
  private var movement: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      VStack(alignment: .leading, spacing: Space.xxs) {
        Text("YOU MOVE")
          .font(.system(size: 8, weight: .medium))
          .tracking(2.0)
          .foregroundStyle(brand.textTertiary)

        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
          Text(from.code)
            .font(.system(size: 20, weight: .regular, design: .serif))
            .foregroundStyle(brand.textSecondary)
          Text(amountText)
            .font(.system(size: 52, weight: .regular, design: .serif).monospacedDigit())
            .tracking(0.2)
            .foregroundStyle(brand.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
          Spacer(minLength: 0)
          CurrencyMark(asset: from, size: 34)
        }
      }

      Slider(value: $amount, in: 10...4000, step: 10)
        .tint(brand.accent)

      VStack(spacing: 0) {
        endRow(label: "FROM", asset: from, selection: $from)
        Rule()
        endRow(label: "TO", asset: to, selection: $to)
      }
      .padding(.horizontal, Space.md)
      .padding(.vertical, 4)
      .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
    }
  }

  /// One end of the movement. A menu rather than a `Picker`: the picker's own
  /// label wraps inside a row like this one, and a row that wraps is a row that
  /// overlaps its neighbour.
  private func endRow(label: String, asset: Asset, selection: Binding<Asset>) -> some View {
    Menu {
      ForEach(Asset.all) { option in
        Button {
          selection.wrappedValue = option
        } label: {
          Text("\(option.code) · \(option.name)")
        }
      }
    } label: {
      HStack(spacing: Space.sm) {
        CurrencyMark(asset: asset, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(label)
            .font(.system(size: 8, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(brand.textTertiary)
          Text(asset.name)
            .font(.system(size: 17, weight: .regular, design: .serif))
            .foregroundStyle(brand.text)
            .lineLimit(1)
        }
        Spacer(minLength: Space.xs)
        Text(balanceText(for: asset))
          .font(.system(size: 14, weight: .regular, design: .serif).monospacedDigit())
          .foregroundStyle(brand.textTertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(brand.textTertiary)
      }
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(label): \(asset.code)")
  }

  private var amountText: String {
    MoneyFormatter.amount(Money(majorUnits: Decimal(amount), currency: from))
  }

  private func balanceText(for asset: Asset) -> String {
    "\(asset.code) \(MoneyFormatter.amount(session.ledger.balance(ofAsset: asset)))"
  }

  // MARK: The price

  @ViewBuilder
  private var quoteLines: some View {
    if let quote {
      VStack(spacing: Space.sm) {
        FieldLine(label: "Rate", value: quote.rateLabel)
        Rule()
        FieldLine(label: "Fee", value: quote.fee.display)
        Rule(accented: true)
        FieldLine(label: "They receive", value: quote.toAmount.display, strong: true)
      }
      .padding(Space.md)
      .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
    }

    if let error {
      Note(error, tone: .negative)
    }
  }

  @ViewBuilder
  private var action: some View {
    if let quote {
      Button("Move \(quote.fromAmount.display)") { execute(quote) }
        .buttonStyle(AureaButtonStyle(kind: .filled))
    } else {
      Button("Get a rate") { quoteIt() }
        .buttonStyle(AureaButtonStyle(kind: .filled))
    }
  }

  // MARK: Where it can go

  /// Rails and people, not settings. Pix first because it is the everyday one,
  /// then the saved wallets, then the door to a payment that needs reviewing.
  private var destinations: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionLabel("Send to")

      VStack(spacing: 0) {
        Button {
          Task { await session.loadSampleRequest() }
        } label: {
          destinationRow(
            mark: { PixMark(size: 24) },
            title: "Pix",
            detail: "Brazilian Real · instant · sample request",
            trailing: "BRL 150.00"
          )
        }
        .buttonStyle(.plain)

        ForEach(Array(AddressBook.all.enumerated()), id: \.element.value) { index, address in
          if index > 0 { Rule() }
          Button {
            from = .usdc
            confirm = TransferDraft(
              asset: .usdc,
              to: address,
              amount: Money(majorUnits: 100, currency: .usdc),
              fee: Money(minorUnits: 120_000, currency: .usdc)
            )
          } label: {
            destinationRow(
              mark: { CurrencyMark(asset: .usdc, size: 40) },
              title: address.label ?? address.short,
              detail: "\(address.network.displayName) · \(address.short)",
              trailing: "USDC 100.00"
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, Space.md)
      .padding(.vertical, 4)
      .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
    }
  }

  private func destinationRow<Mark: View>(
    @ViewBuilder mark: () -> Mark, title: String, detail: String, trailing: String
  ) -> some View {
    HStack(spacing: Space.sm) {
      ZStack {
        Circle().fill(brand.accentTint)
        mark()
      }
      .frame(width: 40, height: 40)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 17, weight: .regular, design: .serif))
          .foregroundStyle(brand.text)
        Text(detail)
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(brand.textTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: Space.xs)
      Text(trailing)
        .font(.system(size: 13, weight: .regular, design: .serif).monospacedDigit())
        .foregroundStyle(brand.textSecondary)
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(brand.textTertiary)
    }
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }

  // MARK: Anything that arrives as text

  /// An invoice, a Pix key, a screenshot of a request. The reading is the
  /// product's job; typing it is not.
  private var requests: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionLabel("A request, read for you")

      VStack(alignment: .leading, spacing: Space.sm) {
        TextField("Paste an invoice, a Pix key or a message", text: $pasted, axis: .vertical)
          .font(.system(size: 16, design: .serif))
          .lineLimit(2...6)
          .padding(Space.md)
          .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
              .strokeBorder(brand.hairline, lineWidth: 1)
          }

        HStack(spacing: Space.xs) {
          Button("Read it") {
            let text = pasted
            pasted = ""
            Task { await session.prepareFromPastedText(text) }
          }
          .buttonStyle(AureaButtonStyle(kind: .outlined))
          .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .opacity(pasted.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)

          Button("Ambiguous") {
            Task { await session.prepareForAmbiguousPayee() }
          }
          .buttonStyle(AureaButtonStyle(kind: .outlined))
        }
        .accessibilityElement(children: .contain)

        // The two demonstration paths, named plainly so the demo can find them.
        VStack(spacing: Space.xs) {
          Button("Load the sample Pix request") {
            Task { await session.loadSampleRequest() }
          }
          .buttonStyle(AureaButtonStyle(kind: .outlined))

          Button("Try an ambiguous recipient") {
            Task { await session.prepareForAmbiguousPayee() }
          }
          .buttonStyle(AureaButtonStyle(kind: .outlined))
        }
      }
    }
  }

  private var closing: some View {
    HStack(spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 1) {
        Text("A CALMER")
        Text("FINANCIAL TOMORROW")
      }
      .font(.system(size: 8, weight: .medium))
      .tracking(1.9)
      .foregroundStyle(brand.textTertiary.opacity(0.85))

      Rectangle()
        .fill(brand.hairline)
        .frame(height: 1)
    }
    .padding(.top, Space.xs)
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 8, weight: .medium))
      .tracking(2.2)
      .foregroundStyle(brand.textTertiary)
  }

  // MARK: Doing it

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
