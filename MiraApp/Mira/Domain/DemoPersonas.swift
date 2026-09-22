import Foundation

// MARK: - The cast
//
// Six people, three to a brand. A profile is not a skin: it is the whole
// session — the ledger, the subscriptions, the goals, the bills, the fees, the
// flagged charge, the plan, the card. Everything a screen reads comes from the
// persona that was chosen, so two people can be driven one after the other
// without either one's numbers surviving into the other's session.
//
// The amounts here are opening positions. The activity seeds are balanced
// journal entries; whatever they net to, a single brought-forward entry brings
// each asset to the figure below, so the opening balances are exact and the
// book still balances per asset.

// MARK: - An activity seed

/// One line of recent history, in the shape the ledger takes: a memo, when it
/// happened, and the postings it moves. The builders keep the common shapes
/// (a card spend, an inflow, a conversion, a pending deposit) balanced by
/// construction, so a seed can be written as a sentence.
struct DemoActivitySeed: Sendable {
  let daysAgo: Int
  let hour: Int
  let memo: String
  let postings: [Posting]

  /// Money out of a spendable account to the outside world.
  static func spend(_ amount: Money, daysAgo: Int, memo: String, hour: Int = 10) -> DemoActivitySeed {
    DemoActivitySeed(
      daysAgo: daysAgo, hour: hour, memo: memo,
      postings: [
        Posting(accountId: Ledger.accountId(for: amount.currency), amount: amount.negated),
        Posting(accountId: externalAccount(amount.currency), amount: amount),
      ])
  }

  /// A spend that also paid a fee, the way an ATM or a weekend transfer does.
  static func spendWithFee(
    _ amount: Money, fee: Money, daysAgo: Int, memo: String, hour: Int = 11
  ) -> DemoActivitySeed {
    DemoActivitySeed(
      daysAgo: daysAgo, hour: hour, memo: memo,
      postings: [
        Posting(
          accountId: Ledger.accountId(for: amount.currency),
          amount: amount.negated.minus(fee)),
        Posting(accountId: feeAccount(amount.currency), amount: fee),
        Posting(accountId: externalAccount(amount.currency), amount: amount),
      ])
  }

  /// Money in to a spendable account.
  static func income(_ amount: Money, daysAgo: Int, memo: String, hour: Int = 9) -> DemoActivitySeed {
    DemoActivitySeed(
      daysAgo: daysAgo, hour: hour, memo: memo,
      postings: [
        Posting(accountId: externalAccount(amount.currency), amount: amount.negated),
        Posting(accountId: Ledger.accountId(for: amount.currency), amount: amount),
      ])
  }

  /// A deposit that has been signalled and has not cleared.
  static func pending(_ amount: Money, daysAgo: Int, memo: String, hour: Int = 9) -> DemoActivitySeed {
    DemoActivitySeed(
      daysAgo: daysAgo, hour: hour, memo: memo,
      postings: [
        Posting(accountId: externalAccount(amount.currency), amount: amount.negated),
        Posting(accountId: "usd.pending", amount: amount),
      ])
  }

  /// A conversion: the source leg, the target leg, and the clearing postings
  /// that keep the rate explicit. No implicit rate is ever assumed.
  static func convert(
    _ from: Money, to: Money, daysAgo: Int, memo: String, hour: Int = 12
  ) -> DemoActivitySeed {
    DemoActivitySeed(
      daysAgo: daysAgo, hour: hour, memo: memo,
      postings: [
        Posting(accountId: Ledger.accountId(for: from.currency), amount: from.negated),
        Posting(accountId: clearingAccount(from.currency), amount: from),
        Posting(accountId: clearingAccount(to.currency), amount: to.negated),
        Posting(accountId: Ledger.accountId(for: to.currency), amount: to),
      ])
  }

  static func externalAccount(_ asset: Asset) -> String { "world.\(asset.code.lowercased())" }
  static func feeAccount(_ asset: Asset) -> String { "fees.\(asset.code.lowercased())" }
  static func clearingAccount(_ asset: Asset) -> String {
    asset == .usd ? "fx.clearing" : "fx.clearing.\(asset.code.lowercased())"
  }
}

private extension Money {
  var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }
  func minus(_ other: Money) -> Money { Money(minorUnits: minorUnits - other.minorUnits, currency: currency) }
}

// MARK: - A persona

struct DemoPersona: Identifiable, Sendable {
  /// The slug the choice is persisted under, e.g. `orion-thiago`.
  let id: String
  let name: String
  let age: Int
  let city: String
  let brand: BrandKind
  let oneLiner: String
  /// A sentence or two of the person's situation, for the record.
  let story: String
  /// The catalog avatar id, e.g. `user-orion-thiago`.
  let avatarAsset: String
  let context: UserContext

  /// The line under the name in the chooser: "USD 7,800 a month".
  let incomeLine: String
  let monthlyIncome: Money
  /// The person's own week, in the currency they spend it in.
  let weeklyBudget: Money

  /// The plan is kept in USD, the way the account's cleared leg is. These are
  /// the persona's own figures expressed in that leg.
  let planBillsUSD: Decimal
  let planReserveUSD: Decimal
  let planWeeklyUSD: Decimal

  /// Opening balances, by asset. The brought-forward entry makes these exact.
  let openingBalances: [Asset: Money]
  let pendingUSD: Money

  let activity: [DemoActivitySeed]
  let subscriptions: [Subscription]
  let goals: [Goal]
  let bills: [NegotiableBill]
  let fees: [FeeEvent]
  let flagged: [FlaggedCharge]
  let cardFrozen: Bool

  let accountOpenedMonthsAgo: Int
  let creditLimitMinor: Int64
  let creditBalanceMinor: Int64
  let statementDay: Int

  /// The plan for this person, from their own figures. It is a proposal until
  /// they approve it, exactly as the first proposal was.
  func plan(total: Money, now: Date = Date()) -> AllocationPlan {
    var plan = AllocationPlan(
      total: total,
      knownBills: PlanInput(value: planBillsUSD, unit: "USD", updatedAt: now, source: .miraSuggested),
      reserve: PlanInput(value: planReserveUSD, unit: "USD", updatedAt: now, source: .miraSuggested),
      weeklyBudget: PlanInput(value: planWeeklyUSD, unit: "USD", updatedAt: now, source: .miraSuggested),
      durationWeeks: 4,
      durationUpdatedAt: now
    )
    plan.rebuildWeeks()
    plan.isApproved = false
    plan.approvedAt = nil
    return plan
  }
}

// MARK: - The six

enum DemoPersonas {
  static func forBrand(_ brand: BrandKind, now: Date = Date()) -> [DemoPersona] {
    switch brand {
    case .orion: return [thiago(now: now), valentina(now: now), mateo(now: now)]
    case .aurea: return [helena(now: now), rafael(now: now), ines(now: now)]
    }
  }

  static func persona(id: String) -> DemoPersona? {
    for brand in BrandKind.allCases {
      if let match = forBrand(brand).first(where: { $0.id == id }) { return match }
    }
    return nil
  }

  /// The profile a brand opens as when nothing has been chosen yet.
  static func defaultPersona(for brand: BrandKind) -> DemoPersona {
    forBrand(brand)[0]
  }

  // MARK: 2.1 Thiago Ramos · orion-thiago
  //
  // Remote salary, local life. Subscription-heavy, card-first, Pix for the
  // small things. His anomaly is the cloud host billing twice in one day.

  static func thiago(now: Date = Date()) -> DemoPersona {
    let usd = Asset.usd
    let brl = Asset.brl
    let usdc = Asset.usdc
    return DemoPersona(
      id: "orion-thiago",
      name: "Thiago Ramos",
      age: 27,
      city: "Florianópolis",
      brand: .orion,
      oneLiner: "Remote salary, local life, and a shelf of subscriptions.",
      story:
        "Backend engineer for a US company, living in Florianópolis. Paid in dollars, spends in reais, and keeps a USDC balance for the months a client is slow.",
      avatarAsset: "user-orion-thiago",
      context: UserContext(
        legalResidence: .brazil, documentCountry: .brazil, presentLocation: .brazil,
        preferredLanguage: .english, paymentDestination: .brazil),
      incomeLine: "USD 7,800 a month",
      monthlyIncome: Money(majorUnits: 7_800, currency: usd),
      weeklyBudget: Money(majorUnits: 700, currency: usd),
      planBillsUSD: 2_400,
      planReserveUSD: 2_500,
      planWeeklyUSD: 700,
      openingBalances: [
        usd: Money(majorUnits: 8_420, currency: usd),
        brl: Money(majorUnits: 1_180, currency: brl),
        usdc: Money(majorUnits: 1_250, currency: usdc),
      ],
      pendingUSD: Money(majorUnits: 2_150, currency: usd),
      activity: [
        .income(Money(majorUnits: 7_800, currency: usd), daysAgo: 0, memo: "Salary deposit · Northwind"),
        .pending(Money(majorUnits: 2_150, currency: usd), daysAgo: 0, memo: "Northwind invoice · on its way"),
        .spend(Money(majorUnits: 24, currency: usd), daysAgo: 1, memo: "Cloud hosting, monthly", hour: 9),
        .spend(Money(majorUnits: 24, currency: usd), daysAgo: 1, memo: "Cloud hosting, monthly", hour: 9),
        .spend(Money(majorUnits: 15, currency: usd), daysAgo: 2, memo: "Figma, monthly"),
        .spend(Money(majorUnits: 10, currency: usd), daysAgo: 2, memo: "Notion Plus, monthly"),
        .spend(Money(majorUnits: 59.99, currency: usd), daysAgo: 3, memo: "Adobe Creative Cloud, monthly"),
        .spend(Money(majorUnits: 68.90, currency: brl), daysAgo: 3, memo: "iFood"),
        .spend(Money(majorUnits: 52.40, currency: brl), daysAgo: 4, memo: "iFood"),
        .spend(Money(majorUnits: 31.20, currency: brl), daysAgo: 5, memo: "Uber"),
        .spend(Money(majorUnits: 99.90, currency: brl), daysAgo: 6, memo: "Smart Fit, monthly"),
        .convert(
          Money(majorUnits: 500, currency: usd), to: Money(majorUnits: 500, currency: usdc),
          daysAgo: 7, memo: "Transfer to USDC"),
        .spend(Money(majorUnits: 1_200, currency: usd), daysAgo: 9, memo: "Tax set-aside"),
        .income(Money(majorUnits: 240, currency: brl), daysAgo: 10, memo: "Pix from Rui · dinner split"),
      ],
      subscriptions: subs(.orion, [
        sub("Netflix Standard", 1_549, usd, day: 4),
        sub("Spotify Premium", 1_199, usd, day: 9),
        sub("iCloud+ 200 GB", 299, usd, day: 15),
        sub("Adobe Creative Cloud", 5_999, usd, day: 22),
        sub("Notion Plus", 1_000, usd, day: 24),
        sub("ChatGPT Plus", 2_000, usd, day: 26),
        sub("GitHub Copilot", 1_000, usd, day: 18),
        sub("YouTube Premium", 1_399, usd, day: 21),
        sub("Smart Fit", 2_490, usd, day: 5),
        sub("iFood Clube", 599, usd, day: 28),
        sub("Max", 1_599, usd, day: 19, lastUsed: 96),
      ]),
      goals: [
        goal("MacBook Pro", target: 2_400, saved: 1_050, usd, art: "goal-orion-thiago-macbook",
             story: "Can I afford the MacBook this month?", createdDaysAgo: 180),
        goal("Japan in April", target: 4_200, saved: 1_480, usd, art: "goal-orion-thiago-japan",
             story: "Tokyo in April, for the whole blossom season.", createdDaysAgo: 240),
        goal("One year of runway", target: 24_000, saved: 3_100, usd, art: "goal-orion-thiago-runway",
             story: "Put 20% of the Northwind payment into the runway.", createdDaysAgo: 300),
      ],
      bills: [],
      fees: [
        FeeEvent(kind: .fx, amountMinor: 240, currencyCode: "USD", at: daysAgo(7, now), note: "Transfer to USDC"),
        FeeEvent(kind: .atm, amountMinor: 3_290, currencyCode: "BRL", at: daysAgo(12, now), note: "Withdrawal at an ATM"),
        FeeEvent(kind: .weekend, amountMinor: 990, currencyCode: "BRL", at: daysAgo(20, now), note: "Transfer sent on a Sunday"),
      ],
      flagged: [
        FlaggedCharge(
          merchant: "UNKNOWN*LOJA-99", amountMinor: 8_990, currencyCode: "BRL",
          at: Calendar.current.date(byAdding: .hour, value: -9, to: now) ?? now,
          reason: "A merchant you have never used, at 3:12 in the morning.")
      ],
      cardFrozen: false,
      accountOpenedMonthsAgo: 9,
      creditLimitMinor: 800_000, creditBalanceMinor: 210_000, statementDay: 22)
  }

  // MARK: 2.2 Valentina Ríos · orion-valentina
  //
  // Lumpy income, smoothed by hand. Watches fees and rates, buys later when a
  // big invoice lands. Her anomaly is Adobe billing twice in 24 hours.

  static func valentina(now: Date = Date()) -> DemoPersona {
    let usd = Asset.usd
    let eur = Asset.eur
    return DemoPersona(
      id: "orion-valentina",
      name: "Valentina Ríos",
      age: 34,
      city: "Buenos Aires",
      brand: .orion,
      oneLiner: "Lumpy income, smoothed by hand.",
      story:
        "Independent brand designer with clients in the US and Europe. Two payments never look alike, so the buffer matters more than the budget.",
      avatarAsset: "user-orion-valentina",
      context: UserContext(
        legalResidence: .argentina, documentCountry: .argentina, presentLocation: .argentina,
        preferredLanguage: .english, paymentDestination: .argentina),
      incomeLine: "USD 3,500–9,000 a month",
      monthlyIncome: Money(majorUnits: 6_000, currency: usd),
      weeklyBudget: Money(majorUnits: 420, currency: usd),
      planBillsUSD: 900,
      planReserveUSD: 600,
      planWeeklyUSD: 420,
      openingBalances: [
        usd: Money(majorUnits: 3_180, currency: usd),
        eur: Money(majorUnits: 260, currency: eur),
      ],
      pendingUSD: Money(majorUnits: 1_900, currency: usd),
      activity: [
        .pending(Money(majorUnits: 1_900, currency: usd), daysAgo: 0, memo: "Kessler invoice · on its way"),
        .income(Money(majorUnits: 4_500, currency: usd), daysAgo: 1, memo: "Client payment · Studio Marchetti"),
        .income(Money(majorUnits: 1_200, currency: usd), daysAgo: 2, memo: "Client payment · Kessler & Co"),
        .spend(Money(majorUnits: 59.99, currency: usd), daysAgo: 3, memo: "Adobe Creative Cloud, monthly", hour: 9),
        .spend(Money(majorUnits: 59.99, currency: usd), daysAgo: 3, memo: "Adobe Creative Cloud, monthly", hour: 21),
        .spend(Money(majorUnits: 15, currency: usd), daysAgo: 4, memo: "Figma, monthly"),
        .spend(Money(majorUnits: 220, currency: usd), daysAgo: 5, memo: "Co-working desk, monthly"),
        .spend(Money(majorUnits: 78, currency: usd), daysAgo: 6, memo: "Dinner · Oviedo"),
        .spendWithFee(
          Money(majorUnits: 400, currency: usd), fee: Money(majorUnits: 1.20, currency: usd),
          daysAgo: 7, memo: "Weekend transfer"),
        .spendWithFee(
          Money(majorUnits: 200, currency: usd), fee: Money(majorUnits: 3, currency: usd),
          daysAgo: 9, memo: "ATM withdrawal · Montevideo"),
        .spend(Money(majorUnits: 13, currency: usd), daysAgo: 10, memo: "Duolingo, monthly"),
        .spend(Money(majorUnits: 12, currency: usd), daysAgo: 12, memo: "Strava, monthly"),
        .convert(
          Money(majorUnits: 300, currency: usd), to: Money(majorUnits: 260, currency: eur),
          daysAgo: 13, memo: "Transfer to EUR"),
        .spend(Money(majorUnits: 45, currency: usd), daysAgo: 15, memo: "Run club membership"),
      ],
      subscriptions: subs(.orion, [
        sub("Adobe Creative Cloud", 5_999, usd, day: 3),
        sub("Figma", 1_500, usd, day: 4),
        sub("Notion Plus", 1_000, usd, day: 24),
        sub("Canva Pro", 1_299, usd, day: 16),
        sub("Spotify Premium", 1_199, usd, day: 9),
        sub("Netflix Standard", 1_549, usd, day: 4),
        sub("Dropbox", 1_199, usd, day: 20),
        sub("ChatGPT Plus", 2_000, usd, day: 26),
        sub("Duolingo", 1_299, usd, day: 10),
        sub("Strava", 1_199, usd, day: 12),
        sub("Deezer", 1_199, usd, day: 23, lastUsed: 140),
      ]),
      goals: [
        goal("Studio deposit", target: 6_000, saved: 2_350, usd, art: "goal-orion-valentina-studio",
             story: "This month is thin — what can I move?", createdDaysAgo: 150),
        goal("Madrid move", target: 9_500, saved: 2_100, usd, art: "goal-orion-valentina-madrid",
             story: "Madrid next year, when the lease is up.", createdDaysAgo: 210),
        goal("Camera kit", target: 2_800, saved: 640, usd, art: "goal-orion-valentina-camera",
             story: "Move 300 to the studio fund.", createdDaysAgo: 90),
      ],
      bills: [],
      fees: [
        FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "USD", at: daysAgo(13, now), note: "Conversion to euros"),
        FeeEvent(kind: .atm, amountMinor: 300, currencyCode: "USD", at: daysAgo(9, now), note: "Withdrawal abroad"),
        FeeEvent(kind: .weekend, amountMinor: 120, currencyCode: "USD", at: daysAgo(7, now), note: "Transfer sent on a Sunday"),
      ],
      flagged: [
        FlaggedCharge(
          merchant: "UNKNOWN*ONLINE-41", amountMinor: 4_990, currencyCode: "USD",
          at: Calendar.current.date(byAdding: .hour, value: -7, to: now) ?? now,
          reason: "An online store you have never used, just after 1 in the morning.")
      ],
      cardFrozen: false,
      accountOpenedMonthsAgo: 14,
      creditLimitMinor: 900_000, creditBalanceMinor: 180_000, statementDay: 18)
  }

  // MARK: 2.3 Mateo Silva · orion-mateo
  //
  // Small money, real decisions. Many small spends that deplete fast, and the
  // first tiny goals. His anomaly is iFood Clube billing twice.

  static func mateo(now: Date = Date()) -> DemoPersona {
    let usd = Asset.usd
    let brl = Asset.brl
    return DemoPersona(
      id: "orion-mateo",
      name: "Mateo Silva",
      age: 21,
      city: "São Paulo",
      brand: .orion,
      oneLiner: "Small money, real decisions.",
      story:
        "Colombian exchange student and junior developer in São Paulo. The internship pays in dollars, the month happens in reais, and the two do not always meet.",
      avatarAsset: "user-orion-mateo",
      context: UserContext(
        legalResidence: .brazil, documentCountry: .colombia, presentLocation: .brazil,
        preferredLanguage: .english, paymentDestination: .brazil),
      incomeLine: "USD 900 a month",
      monthlyIncome: Money(majorUnits: 900, currency: usd),
      weeklyBudget: Money(majorUnits: 110, currency: usd),
      planBillsUSD: 40,
      planReserveUSD: 80,
      planWeeklyUSD: 110,
      openingBalances: [
        usd: Money(majorUnits: 620, currency: usd),
        brl: Money(majorUnits: 340, currency: brl),
      ],
      pendingUSD: Money(majorUnits: 180, currency: usd),
      activity: [
        .income(Money(majorUnits: 700, currency: usd), daysAgo: 0, memo: "Internship stipend"),
        .income(Money(majorUnits: 200, currency: usd), daysAgo: 1, memo: "Family transfer"),
        .pending(Money(majorUnits: 180, currency: usd), daysAgo: 0, memo: "Family top-up · on its way"),
        .spend(Money(majorUnits: 42.90, currency: brl), daysAgo: 1, memo: "iFood"),
        .spend(Money(majorUnits: 36.50, currency: brl), daysAgo: 2, memo: "iFood"),
        .spend(Money(majorUnits: 12.90, currency: brl), daysAgo: 3, memo: "iFood Clube, monthly", hour: 9),
        .spend(Money(majorUnits: 12.90, currency: brl), daysAgo: 3, memo: "iFood Clube, monthly", hour: 19),
        .spend(Money(majorUnits: 24.30, currency: brl), daysAgo: 4, memo: "Uber"),
        .spend(Money(majorUnits: 50, currency: brl), daysAgo: 5, memo: "Metro top-up"),
        .spend(Money(majorUnits: 60, currency: brl), daysAgo: 6, memo: "Cinema"),
        .spend(Money(majorUnits: 30, currency: brl), daysAgo: 7, memo: "Phone credit"),
        .convert(
          Money(majorUnits: 300, currency: brl), to: Money(majorUnits: 60, currency: usd),
          daysAgo: 8, memo: "Bought USD for the month"),
        .spend(Money(majorUnits: 34.90, currency: brl), daysAgo: 11, memo: "iFood"),
      ],
      subscriptions: subs(.orion, [
        sub("Spotify Premium (student)", 1_190, brl, day: 9),
        sub("iFood Clube", 1_290, brl, day: 28),
        sub("Globoplay", 2_490, brl, day: 17),
        sub("Duolingo", 3_490, brl, day: 10),
        sub("Smart Fit", 4_990, brl, day: 5),
      ]),
      goals: [
        goal("Rio weekend", target: 900, saved: 260, brl, art: "goal-orion-mateo-rio",
             story: "Rio with the course, when the semester ends.", createdDaysAgo: 60),
        goal("A bike", target: 1_800, saved: 420, brl, art: "goal-orion-mateo-bike",
             story: "Set aside 50 for the bike.", createdDaysAgo: 120),
        goal("Emergency pad", target: 500, saved: 120, usd, art: "goal-orion-mateo-emergency",
             story: "How much can I spend tonight?", createdDaysAgo: 45),
      ],
      bills: [],
      fees: [
        FeeEvent(kind: .fx, amountMinor: 490, currencyCode: "BRL", at: daysAgo(8, now), note: "Bought dollars"),
        FeeEvent(kind: .atm, amountMinor: 2_490, currencyCode: "BRL", at: daysAgo(16, now), note: "Withdrawal at an ATM"),
        FeeEvent(kind: .transfer, amountMinor: 490, currencyCode: "BRL", at: daysAgo(22, now), note: "Instant transfer"),
      ],
      flagged: [
        FlaggedCharge(
          merchant: "UNKNOWN*LOJA-99", amountMinor: 6_490, currencyCode: "BRL",
          at: Calendar.current.date(byAdding: .hour, value: -8, to: now) ?? now,
          reason: "A merchant you have never used, at 3:04 in the morning.")
      ],
      cardFrozen: false,
      accountOpenedMonthsAgo: 5,
      creditLimitMinor: 300_000, creditBalanceMinor: 95_000, statementDay: 12)
  }

  // MARK: 2.4 Helena Duarte · aurea-helena
  //
  // Few movements, all of them large. Sells to international collectors, keeps
  // a deep reserve, never day-trades the account. Her anomaly is the shipping
  // insurer billing twice, and her atelier electricity is up for negotiation.

  static func helena(now: Date = Date()) -> DemoPersona {
    let usd = Asset.usd
    let eur = Asset.eur
    return DemoPersona(
      id: "aurea-helena",
      name: "Helena Duarte",
      age: 52,
      city: "Lisbon",
      brand: .aurea,
      oneLiner: "Few movements, all of them large.",
      story:
        "Runs a gallery in Lisbon and sells to collectors in New York and São Paulo. Family and artists keep her travelling to Brazil; the reserve is never touched for a season.",
      avatarAsset: "user-aurea-helena",
      context: UserContext(
        legalResidence: .portugal, documentCountry: .portugal, presentLocation: .portugal,
        preferredLanguage: .english, paymentDestination: .brazil),
      incomeLine: "large, lumpy sales",
      monthlyIncome: Money(majorUnits: 30_000, currency: usd),
      weeklyBudget: Money(majorUnits: 3_000, currency: usd),
      planBillsUSD: 6_000,
      planReserveUSD: 20_000,
      planWeeklyUSD: 3_000,
      openingBalances: [
        usd: Money(majorUnits: 42_000, currency: usd),
        eur: Money(majorUnits: 9_400, currency: eur),
      ],
      pendingUSD: Money(majorUnits: 18_000, currency: usd),
      activity: [
        .pending(Money(majorUnits: 18_000, currency: usd), daysAgo: 0, memo: "New York sale · settlement on its way"),
        .income(Money(majorUnits: 26_000, currency: usd), daysAgo: 1, memo: "Collector payment · Fundação Ática"),
        .spend(Money(majorUnits: 1_850, currency: usd), daysAgo: 2, memo: "Shipping insurance", hour: 10),
        .spend(Money(majorUnits: 1_850, currency: usd), daysAgo: 2, memo: "Shipping insurance", hour: 16),
        .spend(Money(majorUnits: 65, currency: eur), daysAgo: 3, memo: "ArtLogic, monthly"),
        .spend(Money(majorUnits: 480, currency: eur), daysAgo: 4, memo: "Florist · opening night"),
        .spend(Money(majorUnits: 1_240, currency: eur), daysAgo: 5, memo: "Hotel · Basel"),
        .spend(Money(majorUnits: 4_800, currency: usd), daysAgo: 6, memo: "Restoration studio · second phase"),
        .spend(Money(majorUnits: 20_000, currency: usd), daysAgo: 8, memo: "Transfer to the reserve"),
        .convert(
          Money(majorUnits: 3_000, currency: usd), to: Money(majorUnits: 2_760, currency: eur),
          daysAgo: 10, memo: "EUR top-up"),
        .spend(Money(majorUnits: 620, currency: eur), daysAgo: 14, memo: "Art fair travel · São Paulo"),
      ],
      subscriptions: subs(.aurea, [
        sub("iCloud+ 200 GB", 299, eur, day: 15),
        sub("Dropbox", 1_199, eur, day: 20),
        sub("Adobe Photography", 2_419, eur, day: 22),
        sub("Notion", 1_000, eur, day: 24),
        sub("Telegram Premium", 499, eur, day: 8),
        sub("ArtLogic", 6_500, eur, day: 3),
        sub("Artforum", 999, eur, day: 11),
      ]),
      goals: [
        goal("A year in Tuscany", target: 36_000, saved: 11_500, usd, art: "goal-aurea-helena-tuscany",
             story: "A year in Tuscany, once the gallery can spare me.", createdDaysAgo: 400),
        goal("The chapel fresco", target: 24_000, saved: 6_200, eur, art: "goal-aurea-helena-chapel",
             story: "Can I fund the restorer's second phase in June?", createdDaysAgo: 260),
        goal("The gallery's endowment", target: 120_000, saved: 34_000, usd, art: "goal-aurea-helena-endowment",
             story: "Move 20,000 into the reserve before Basel.", createdDaysAgo: 700),
      ],
      bills: [
        NegotiableBill(
          name: "Atelier electricity", monthlyMinor: 21_400, currencyCode: "EUR", renewalInDays: 12,
          competitor: "Luz Ibérica", competitorMonthlyMinor: 15_900)
      ],
      fees: [
        FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "EUR", at: daysAgo(10, now), note: "Conversion from dollars"),
        FeeEvent(kind: .transfer, amountMinor: 490, currencyCode: "USD", at: daysAgo(8, now), note: "Transfer to the reserve"),
        FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "EUR", at: daysAgo(48, now), note: "Card spend in dollars"),
      ],
      flagged: [],
      cardFrozen: false,
      accountOpenedMonthsAgo: 96,
      creditLimitMinor: 5_000_000, creditBalanceMinor: 1_450_000, statementDay: 22)
  }

  // MARK: 2.5 Rafael Moraes · aurea-rafael
  //
  // A life in hotels, one instrument that matters. Hotels and trains across
  // cities, an instrument insured annually. His anomaly is the Vienna hotel
  // billing twice.

  static func rafael(now: Date = Date()) -> DemoPersona {
    let eur = Asset.eur
    let usd = Asset.usd
    let brl = Asset.brl
    return DemoPersona(
      id: "aurea-rafael",
      name: "Rafael Moraes",
      age: 38,
      city: "Madrid",
      brand: .aurea,
      oneLiner: "A life in hotels, one instrument that matters.",
      story:
        "Principal cellist on tour, Brazilian, based in Madrid. The orchestra pays in euros, teaching pays in dollars, and the family in Porto Alegre is one transfer away.",
      avatarAsset: "user-aurea-rafael",
      context: UserContext(
        legalResidence: .spain, documentCountry: .brazil, presentLocation: .spain,
        preferredLanguage: .english, paymentDestination: .brazil),
      incomeLine: "EUR 4,200 a month",
      monthlyIncome: Money(majorUnits: 4_200, currency: eur),
      weeklyBudget: Money(majorUnits: 620, currency: eur),
      planBillsUSD: 500,
      planReserveUSD: 700,
      planWeeklyUSD: 400,
      openingBalances: [
        eur: Money(majorUnits: 6_800, currency: eur),
        usd: Money(majorUnits: 2_900, currency: usd),
        brl: Money(majorUnits: 1_500, currency: brl),
      ],
      pendingUSD: Money(majorUnits: 0, currency: usd),
      activity: [
        .income(Money(majorUnits: 4_200, currency: eur), daysAgo: 0, memo: "Orchestra fee"),
        .income(Money(majorUnits: 900, currency: usd), daysAgo: 1, memo: "Teaching transfer"),
        .spend(Money(majorUnits: 480, currency: eur), daysAgo: 2, memo: "Hotel · Vienna", hour: 10),
        .spend(Money(majorUnits: 480, currency: eur), daysAgo: 2, memo: "Hotel · Vienna", hour: 18),
        .spend(Money(majorUnits: 186.40, currency: eur), daysAgo: 3, memo: "Dinner · split four ways"),
        .spend(Money(majorUnits: 96, currency: eur), daysAgo: 4, memo: "Train · Vienna to Munich"),
        .spend(Money(majorUnits: 1_100, currency: eur), daysAgo: 5, memo: "Instrument insurance, annual"),
        .spend(Money(majorUnits: 42, currency: eur), daysAgo: 6, memo: "Henle · sheet music"),
        .convert(
          Money(majorUnits: 800, currency: eur), to: Money(majorUnits: 4_300, currency: brl),
          daysAgo: 7, memo: "Transfer to family · Porto Alegre"),
        .spend(Money(majorUnits: 58, currency: eur), daysAgo: 9, memo: "Strings · Larsen"),
      ],
      subscriptions: subs(.aurea, [
        sub("Spotify Premium", 1_199, eur, day: 9),
        sub("iCloud+ 200 GB", 299, eur, day: 15),
        sub("Dropbox", 1_199, eur, day: 20),
        sub("Adobe Creative Cloud", 2_419, eur, day: 22),
        sub("Digital Concert Hall", 1_290, eur, day: 7),
        sub("Henle", 890, eur, day: 6),
      ]),
      goals: [
        goal("A fine cello", target: 45_000, saved: 12_000, eur, art: "goal-aurea-rafael-cello",
             story: "Move the teaching money into the cello fund.", createdDaysAgo: 500),
        goal("A season in Japan", target: 8_000, saved: 2_300, eur, art: "goal-aurea-rafael-japan",
             story: "What will the Japan season cost, all in?", createdDaysAgo: 200),
        goal("The family house in Porto", target: 90_000, saved: 21_000, eur, art: "goal-aurea-rafael-porto",
             story: "The family house in Porto, one tour at a time.", createdDaysAgo: 620),
      ],
      bills: [],
      fees: [
        FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "EUR", at: daysAgo(7, now), note: "Conversion to reais"),
        FeeEvent(kind: .transfer, amountMinor: 490, currencyCode: "EUR", at: daysAgo(7, now), note: "Transfer to family"),
        FeeEvent(kind: .atm, amountMinor: 2_490, currencyCode: "EUR", at: daysAgo(19, now), note: "Withdrawal abroad"),
      ],
      flagged: [
        FlaggedCharge(
          merchant: "TOKYO*HOTEL-SHOP", amountMinor: 6_200, currencyCode: "EUR",
          at: Calendar.current.date(byAdding: .hour, value: -13, to: now) ?? now,
          reason: "A merchant in Tokyo, on a night the orchestra was elsewhere.")
      ],
      cardFrozen: false,
      accountOpenedMonthsAgo: 60,
      creditLimitMinor: 1_500_000, creditBalanceMinor: 420_000, statementDay: 5)
  }

  // MARK: 2.6 Inés Arriaga · aurea-ines
  //
  // A business in seasons, a life in one place. Equipment before harvest,
  // careful after, and a reserve for frost and hail. Her anomaly is the
  // irrigation equipment billing twice.

  static func ines(now: Date = Date()) -> DemoPersona {
    let usd = Asset.usd
    return DemoPersona(
      id: "aurea-ines",
      name: "Inés Arriaga",
      age: 29,
      city: "Mendoza",
      brand: .aurea,
      oneLiner: "A business in seasons, a life in one place.",
      story:
        "Runs the export side of the family's wine estate in Mendoza. Shipments pay in dollars, the harvest eats the rest of the year, and frost insurance is not optional.",
      avatarAsset: "user-aurea-ines",
      context: UserContext(
        legalResidence: .argentina, documentCountry: .argentina, presentLocation: .argentina,
        preferredLanguage: .english, paymentDestination: .argentina),
      incomeLine: "USD, season by season",
      monthlyIncome: Money(majorUnits: 12_000, currency: usd),
      weeklyBudget: Money(majorUnits: 900, currency: usd),
      planBillsUSD: 2_000,
      planReserveUSD: 3_000,
      planWeeklyUSD: 900,
      openingBalances: [
        usd: Money(majorUnits: 11_600, currency: usd)
      ],
      pendingUSD: Money(majorUnits: 7_400, currency: usd),
      activity: [
        .pending(Money(majorUnits: 7_400, currency: usd), daysAgo: 0, memo: "Export settlement · balance on its way"),
        .income(Money(majorUnits: 9_500, currency: usd), daysAgo: 1, memo: "Export settlement · partial"),
        .spend(Money(majorUnits: 2_300, currency: usd), daysAgo: 2, memo: "Irrigation equipment", hour: 9),
        .spend(Money(majorUnits: 2_300, currency: usd), daysAgo: 2, memo: "Irrigation equipment", hour: 15),
        .spend(Money(majorUnits: 780, currency: usd), daysAgo: 3, memo: "Trade fair travel · Buenos Aires"),
        .spend(Money(majorUnits: 430, currency: usd), daysAgo: 4, memo: "Cellar supplies"),
        .spend(Money(majorUnits: 12, currency: usd), daysAgo: 5, memo: "Strava, monthly"),
        .spend(Money(majorUnits: 13, currency: usd), daysAgo: 6, memo: "Duolingo, monthly"),
        .spend(Money(majorUnits: 3_000, currency: usd), daysAgo: 8, memo: "Set aside for the harvest"),
        .income(Money(majorUnits: 1_150, currency: usd), daysAgo: 12, memo: "Tasting room · weekend sales"),
      ],
      subscriptions: subs(.aurea, [
        sub("Spotify Premium", 1_199, usd, day: 9),
        sub("iCloud+ 200 GB", 299, usd, day: 15),
        sub("Notion Plus", 1_000, usd, day: 24),
        sub("Dropbox", 1_199, usd, day: 20),
        sub("Duolingo", 1_299, usd, day: 10),
        sub("Strava", 1_199, usd, day: 12),
      ]),
      goals: [
        goal("The new press house", target: 60_000, saved: 14_000, usd, art: "goal-aurea-ines-press",
             story: "Move last month's surplus to the press house.", createdDaysAgo: 320),
        goal("Harvest reserve", target: 18_000, saved: 6_500, usd, art: "goal-aurea-ines-harvest",
             story: "How much runway do I have to the harvest?", createdDaysAgo: 180),
        goal("Grandmother's garden", target: 6_000, saved: 2_050, usd, art: "goal-aurea-ines-garden",
             story: "Set aside 10% of the export payment.", createdDaysAgo: 90),
      ],
      bills: [],
      fees: [
        FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "USD", at: daysAgo(1, now), note: "Export settlement conversion"),
        FeeEvent(kind: .atm, amountMinor: 490, currencyCode: "USD", at: daysAgo(17, now), note: "Withdrawal at the fair"),
        FeeEvent(kind: .weekend, amountMinor: 120, currencyCode: "USD", at: daysAgo(26, now), note: "Transfer sent on a Sunday"),
      ],
      flagged: [
        FlaggedCharge(
          merchant: "FERIA*STAND-204", amountMinor: 11_800, currencyCode: "USD",
          at: Calendar.current.date(byAdding: .hour, value: -11, to: now) ?? now,
          reason: "A fair-week merchant, on a day your card stayed at the estate.")
      ],
      cardFrozen: false,
      accountOpenedMonthsAgo: 72,
      creditLimitMinor: 2_000_000, creditBalanceMinor: 640_000, statementDay: 10)
  }

  // MARK: Builders

  /// Every subscription bills to the card this brand actually holds, so no
  /// record needs correcting at the moment of a cancellation.
  private static func subs(_ brand: BrandKind, _ list: [Subscription]) -> [Subscription] {
    let last4 = brand == .orion ? "7182" : "4872"
    return list.map { subscription in
      var copy = subscription
      copy.cardLast4 = last4
      return copy
    }
  }

  private static func sub(
    _ name: String, _ minorUnits: Int64, _ currency: Asset, day: Int,
    lastUsed: Int? = nil, card: String = "4872"
  ) -> Subscription {
    Subscription(
      name: name, amountMinor: minorUnits, currencyCode: currency.code, cadence: .monthly,
      nextChargeDay: day, cardLast4: card, lastUsedDaysAgo: lastUsed)
  }

  private static func goal(
    _ name: String, target: Decimal, saved: Decimal, _ currency: Asset,
    art: String, story: String, createdDaysAgo: Int, protected: Bool = true
  ) -> Goal {
    Goal(
      name: name,
      targetMinor: Money(majorUnits: target, currency: currency).minorUnits,
      savedMinor: Money(majorUnits: saved, currency: currency).minorUnits,
      currencyCode: currency.code,
      protected: protected,
      artAsset: art,
      story: story,
      createdAt: Calendar.current.date(byAdding: .day, value: -createdDaysAgo, to: Date()) ?? Date())
  }

  private static func daysAgo(_ days: Int, _ now: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
  }
}
