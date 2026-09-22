import SwiftUI

// MARK: - Motion

/// A ring that never stops turning.
///
/// Used around the profile button and behind the Mira mark. The motion is slow
/// and continuous: the point is that the app is alive, not that you should look
/// at it. Reduce Motion freezes it at a fixed angle.
struct OrbitRing: View {
  var size: CGFloat = 30
  var color: Color
  var lineWidth: CGFloat = 1
  var period: Double = 11
  /// A brighter arc, so the rotation is legible as movement rather than as a
  /// static circle.
  var highlight: Double = 0.3

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      ring(rotation: 200)
    } else {
      TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        ring(rotation: (t.truncatingRemainder(dividingBy: period) / period) * 360)
      }
    }
  }

  private func ring(rotation: Double) -> some View {
    ZStack {
      Circle()
        .strokeBorder(color.opacity(0.18), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: highlight)
        .stroke(
          color.opacity(0.85),
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(rotation))
    }
    .frame(width: size, height: size)
  }
}

/// A single dot travelling a fixed circular path, forever.
struct OrbitingDot: View {
  var pathSize: CGFloat
  var dotSize: CGFloat = 4
  var color: Color
  var period: Double = 7

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      dot(angle: 0.9)
    } else {
      TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        dot(angle: (t.truncatingRemainder(dividingBy: period) / period) * 2 * .pi)
      }
    }
  }

  private func dot(angle: Double) -> some View {
    Circle()
      .fill(color)
      .frame(width: dotSize, height: dotSize)
      .offset(
        x: cos(angle) * pathSize / 2,
        y: sin(angle) * pathSize / 2
      )
  }
}

// MARK: - Aurea home

/// Mira.
///
/// The printed-plate layout: a serif masthead, one very large heading, account
/// rows carrying their currency marks, the printed card, and a quiet closing
/// rule. Warmth comes from the artwork, not from the background.
struct AureaHome: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var showProfile = false
  @State private var showAddCurrency = false

  private var card: CardMock {
    var c = CardMock.aurea
    c = CardMock(
      id: c.id, nickname: c.nickname, holder: c.holder, pan: c.pan,
      expiry: c.expiry, cvv: c.cvv, network: c.network, kind: c.kind,
      frozen: session.cardFrozen)
    return c
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.lg) {
        header
        accountsHeading
        accountRows
        addCurrency
        cardSection
        cardActions
        closing
      }
      .padding(.horizontal, Space.gutter)
      .readableWidth(620)
      .padding(.bottom, Space.xxl)
    }
    .scrollIndicators(.hidden)
    .sheet(isPresented: $showProfile) { AureaProfile() }
    .sheet(isPresented: $showAddCurrency) { AureaAddCurrency() }
  }

  // MARK: Masthead

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
      profileButton
    }
    .padding(.top, Space.xs)
  }

  /// The one place the app is visibly alive at rest: a ring turning slowly
  /// around the profile mark.
  private var profileButton: some View {
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

  // MARK: Heading

  private var accountsHeading: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
      Text("Accounts")
        .font(.system(size: 46, weight: .regular, design: .serif))
        .tracking(0.2)
        .foregroundStyle(brand.text)
        .minimumScaleFactor(0.6)
        .lineLimit(1)

      Spacer(minLength: 0)

      // The three-word column, with the rule under it that the reference uses.
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

  // MARK: Accounts

  /// One row per currency the user holds, with the foreign balances converted
  /// for comparison. The subtitle says what the account is *for*, which is the
  /// only thing that makes a list of currencies readable.
  private var accountRows: some View {
    VStack(spacing: Space.xs) {
      accountRow(
        asset: .usd,
        title: "US Dollar",
        role: "Primary account",
        amount: session.ledger.balance(ofAsset: .usd),
        symbol: "$"
      )
      accountRow(
        asset: .brl,
        title: "Brazilian Real",
        role: "Everyday spending",
        amount: session.ledger.balance(ofAsset: .brl),
        symbol: "R$"
      )
      accountRow(
        asset: .eur,
        title: "Euro",
        role: "Savings",
        amount: session.ledger.balance(ofAsset: .eur),
        symbol: "€"
      )
      stablecoinRows
    }
  }

  private func accountRow(
    asset: Asset, title: String, role: String, amount: Money, symbol: String
  ) -> some View {
    Button {
      session.requestTab(.move)
    } label: {
      HStack(spacing: Space.sm) {
        CurrencyMark(asset: asset)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 17, weight: .regular, design: .serif))
            .foregroundStyle(brand.text)
          Text(role.uppercased())
            .font(.system(size: 8, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(brand.textTertiary)
        }
        Spacer(minLength: Space.xs)
        Text("\(symbol)\(MoneyFormatter.amount(amount))")
          .font(.system(size: 19, weight: .regular, design: .serif).monospacedDigit())
          .foregroundStyle(amount.minorUnits == 0 ? brand.textTertiary : brand.text)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(brand.textTertiary)
      }
      .padding(.horizontal, Space.md)
      .padding(.vertical, 14)
      .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Stablecoins sit in the same list as currencies, because to the person using
  /// the account they are simply another balance. The row says what they are.
  private var stablecoinRows: some View {
    ForEach(Asset.stablecoins) { asset in
      let amount = session.ledger.balance(ofAsset: asset)
      Button {
        session.requestTab(.move)
      } label: {
        HStack(spacing: Space.sm) {
          CurrencyMark(asset: asset)

          VStack(alignment: .leading, spacing: 2) {
            Text(asset.name)
              .font(.system(size: 17, weight: .regular, design: .serif))
              .foregroundStyle(brand.text)
            Text("STABLECOIN · 6 DECIMALS")
              .font(.system(size: 8, weight: .medium))
              .tracking(1.8)
              .foregroundStyle(brand.textTertiary)
          }
          Spacer(minLength: Space.xs)
          Text(MoneyFormatter.amount(amount))
            .font(.system(size: 19, weight: .regular, design: .serif).monospacedDigit())
            .foregroundStyle(amount.minorUnits == 0 ? brand.textTertiary : brand.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(brand.textTertiary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 14)
        .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(brand.hairline, lineWidth: 1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private var addCurrency: some View {
    Button { showAddCurrency = true } label: {
      HStack(spacing: Space.sm) {
        ZStack {
          Circle().strokeBorder(brand.textTertiary.opacity(0.5), lineWidth: 1)
          Image(systemName: "plus")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(brand.text)
        }
        .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: 2) {
          Text("Add a currency")
            .font(.system(size: 17, weight: .regular, design: .serif))
            .foregroundStyle(brand.text)
          Text("EXPAND YOUR WORLD")
            .font(.system(size: 8, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(brand.textTertiary)
        }
        Spacer(minLength: Space.xs)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(brand.textTertiary)
      }
      .padding(.horizontal, Space.md)
      .padding(.vertical, 14)
      .background(Color.clear, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: Card

  private var cardSection: some View {
    MiraCardFace(card: card, style: .aurea(imageName: "aurea-card"))
      .padding(.top, Space.xs)
  }

  private var cardActions: some View {
    HStack(spacing: Space.xs) {
      Button {
        session.requestTab(.move)
      } label: {
        HStack(spacing: 8) {
          Text("Add money")
          Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .medium))
        }
      }
      .buttonStyle(AureaButtonStyle(kind: .filled))

      Button {
        showProfile = true
      } label: {
        HStack(spacing: 8) {
          Text("Manage card")
          Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .medium))
        }
      }
      .buttonStyle(AureaButtonStyle(kind: .outlined))
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
}

// MARK: - Aurea buttons

/// Aurea's buttons: fully rounded, serif label, burgundy fill or a burgundy
/// hairline. No icons beyond a small arrow.
struct AureaButtonStyle: ButtonStyle {
  enum Kind { case filled, outlined, quiet }
  var kind: Kind = .filled

  @Environment(\.brand) private var brand

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .regular, design: .serif))
      .foregroundStyle(kind == .filled ? brand.canvas : brand.accent)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
      .background(kind == .filled ? brand.accent : Color.clear)
      .overlay {
        if kind == .outlined {
          Capsule().strokeBorder(brand.accent.opacity(0.55), lineWidth: 1)
        }
      }
      .clipShape(Capsule())
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
  }
}

// MARK: - Profile

struct AureaProfile: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @AppStorage("mira.onboarded") private var hasOnboarded = true
  @AppStorage("mira.onboarding.scene") private var onboardingScene = OnboardingScene.fallback.rawValue

  var body: some View {
    NavigationStack {
      ZStack {
        brand.canvas.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            // The card, again, because managing it is why you came here.
            MiraCardFace(card: CardMock.aurea, style: .aurea(imageName: "aurea-card"))

            VStack(alignment: .leading, spacing: Space.sm) {
              sectionLabel("Cards")
              MiraCardFace(
                card: CardMock.aureaVirtual,
                style: .aurea(imageName: "aurea-landscape")
              )
              .opacity(0.96)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
              sectionLabel("Card controls")
              VStack(spacing: 0) {
                Toggle(isOn: Binding(
                  get: { session.cardFrozen },
                  set: { session.setCardFrozen($0) }
                )) {
                  Text("Freeze card")
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(brand.text)
                }
                .tint(brand.accent)
                .padding(.vertical, 10)
              }
              .padding(.horizontal, Space.md)
              .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                  .strokeBorder(brand.hairline, lineWidth: 1)
              }
            }

            VStack(alignment: .leading, spacing: Space.sm) {
              sectionLabel("Pay with")
              HStack(spacing: Space.xs) {
                payChip {
                  HStack(spacing: 8) {
                    PixMark(size: 20)
                    Text("Pix").font(.system(size: 15, design: .serif)).foregroundStyle(brand.text)
                  }
                }
                payChip { NetworkMark(network: .visa, light: false) }
                payChip { NetworkMark(network: .mastercard, light: false) }
              }
            }

            VStack(alignment: .leading, spacing: Space.sm) {
              sectionLabel("Mira controls")
              Button("Receive 100 USDC from Mira Orion") { receive() }
                .buttonStyle(AureaButtonStyle(kind: .outlined))
              Button("Send 100 USDC to Mira Orion") { send() }
                .buttonStyle(AureaButtonStyle(kind: .outlined))
            }

            VStack(alignment: .leading, spacing: Space.sm) {
              sectionLabel("Onboarding scene")
              VStack(spacing: 0) {
                ForEach(OnboardingScene.allCases) { scene in
                  sceneRow(scene)
                  if scene != OnboardingScene.allCases.last {
                    Rule()
                  }
                }
              }
              .padding(.horizontal, Space.md)
              .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                  .strokeBorder(brand.hairline, lineWidth: 1)
              }
              Text("The app opens on the one selected. Both stay in the build until you decide.")
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(brand.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("Replay onboarding") { hasOnboarded = false; dismiss() }
              .buttonStyle(AureaButtonStyle(kind: .outlined))
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(620)
          .padding(.vertical, Space.lg)
        }
      }
      .navigationTitle("Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.tint(brand.accent)
        }
      }
    }
    .presentationBackground(brand.canvas)
  }

  /// One onboarding scene, with the reason to pick it written underneath.
  private func sceneRow(_ scene: OnboardingScene) -> some View {
    let selected = onboardingScene == scene.rawValue
    return Button {
      withAnimation(.easeOut(duration: 0.2)) { onboardingScene = scene.rawValue }
    } label: {
      HStack(alignment: .top, spacing: Space.sm) {
        ZStack {
          Circle()
            .strokeBorder(selected ? brand.accent : brand.textTertiary.opacity(0.5), lineWidth: 1)
          if selected {
            Circle().fill(brand.accent).frame(width: 10, height: 10)
          }
        }
        .frame(width: 22, height: 22)
        .padding(.top, 1)

        VStack(alignment: .leading, spacing: 3) {
          Text(scene.title)
            .font(.system(size: 16, design: .serif))
            .foregroundStyle(brand.text)
          Text(scene.blurb)
            .font(.system(size: 12, design: .serif))
            .foregroundStyle(brand.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Onboarding scene: \(scene.title)")
  }

  private func payChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity)
      .frame(height: 46)
      .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
  }

  /// The receiving half of the cross-app demo. Guarded by the ledger's
  /// idempotency key so a repeat poll cannot credit twice.
  private func receive() {
    session.receiveExternalTransfer(
      asset: .usdc,
      amount: Money(minorUnits: 100_000_000, currency: .usdc),
      from: "Mira Orion",
      idempotencyKey: "mira-in-\(UUID().uuidString.prefix(8))"
    )
  }

  /// The sending half: move value out of this ledger and announce it.
  private func send() {
    Task {
      await session.sendToOtherApp(
        asset: .usdc, amount: Money(minorUnits: 100_000_000, currency: .usdc))
    }
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 8, weight: .medium))
      .tracking(2.2)
      .foregroundStyle(brand.textTertiary)
  }
}

// MARK: - Add currency

struct AureaAddCurrency: View {
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        brand.canvas.ignoresSafeArea()
        ScrollView {
          VStack(spacing: Space.xs) {
            ForEach(Asset.all.filter { $0.kind == .fiat }) { asset in
              HStack(spacing: Space.sm) {
                CurrencyMark(asset: asset)
                VStack(alignment: .leading, spacing: 2) {
                  Text(asset.name)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(brand.text)
                  Text(asset.code)
                    .font(.system(size: 8, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(brand.textTertiary)
                }
                Spacer()
                Image(systemName: "plus")
                  .font(.system(size: 14))
                  .foregroundStyle(brand.accent)
              }
              .padding(.horizontal, Space.md)
              .padding(.vertical, 14)
              .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                  .strokeBorder(brand.hairline, lineWidth: 1)
              }
            }
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(620)
          .padding(.vertical, Space.lg)
        }
      }
      .navigationTitle("Add a currency")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.tint(brand.accent)
        }
      }
    }
    .presentationBackground(brand.canvas)
  }
}
