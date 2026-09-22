import Foundation

// MARK: - Capacity
//
// Nubank's Ultravioleta and Revolut's plans sell a tier. What is defensible
// under the marketing is thinner and better: the account's terms improve with
// the person's own behaviour, and the person can read the arithmetic that put
// them where they are.
//
// So this is deliberately not a product. Four facts the app already holds,
// three tiers, and a `why` that names each fact and what it contributed. No
// model decides a tier, and nothing here persuades anyone to spend. A fresh
// account is Base; behaviour moves it; nothing else does.

enum CapacityTier: String, CaseIterable, Sendable {
  case base
  case steady
  case prime

  var name: String {
    switch self {
    case .base: return "Base"
    case .steady: return "Steady"
    case .prime: return "Prime"
    }
  }

  /// The tier above this one, or nil at the top.
  var next: CapacityTier? {
    switch self {
    case .base: return .steady
    case .steady: return .prime
    case .prime: return nil
    }
  }

  /// The points at which this tier starts.
  var threshold: Int {
    switch self {
    case .base: return 0
    case .steady: return Capacity.steadyAt
    case .prime: return Capacity.primeAt
    }
  }

  /// The FX mark-up on a conversion.
  var fxFee: Decimal {
    switch self {
    case .base: return Decimal(string: "0.018")!
    case .steady: return Decimal(string: "0.009")!
    case .prime: return Decimal(string: "0.004")!
    }
  }

  var fxFeeLabel: String { "\(Self.percent(fxFee)) per conversion" }

  /// The instant-transfer fee, in the account's own money.
  var transferFee: Money {
    switch self {
    case .base: return Money(minorUnits: 490, currency: .brl)
    case .steady: return Money(minorUnits: 290, currency: .brl)
    case .prime: return Money(minorUnits: 190, currency: .brl)
    }
  }

  var transferFeeLabel: String { "\(transferFee.display) per instant transfer" }

  /// What a standing approval covers without asking. Base is the limit the app
  /// already enforces; the tiers above state what they lift it to.
  var standingLimit: Money {
    switch self {
    case .base: return ConsentPolicy.standingLimit
    case .steady: return Money(majorUnits: 600, currency: .usd)
    case .prime: return Money(majorUnits: 1_500, currency: .usd)
    }
  }

  /// The card's base cashback, before the running offers.
  var cashbackRate: Decimal {
    switch self {
    case .base: return Decimal(string: "0.015")!
    case .steady: return Decimal(string: "0.02")!
    case .prime: return Decimal(string: "0.025")!
    }
  }

  var cashbackLabel: String { Self.percent(cashbackRate) }

  /// The four terms in one line, so the chat answer and the document cannot
  /// state different numbers.
  var termsLine: String {
    "\(fxFeeLabel), \(transferFeeLabel), standing approval to \(standingLimit.display) per order, "
      + "\(cashbackLabel) base cashback"
  }

  /// "1.8%" where the rate is whole, one decimal where it is not.
  private static func percent(_ rate: Decimal) -> String {
    let value = NSDecimalNumber(decimal: rate * 100).doubleValue
    return value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
  }
}

enum Capacity {
  /// The facts the tier is computed from, each one already the app's own
  /// record. Money carries its own currency: a band is read in that currency
  /// and never converted into another one.
  struct Facts: Equatable, Sendable {
    /// Whole months since the account opened.
    var monthsOpen: Int = 0
    /// Charges stopped at the card while they were still expected. Each one
    /// costs a month of on-time credit; a block that follows a cancellation is
    /// housekeeping and the store does not count it here.
    var blockedCharges: Int = 0
    /// The balance the account usually holds.
    var averageBalance: Money = .zero(.usd)
    /// Progress toward the person's own funds, 0…1, averaged per fund so two
    /// currencies are never summed.
    var savingsKept: Decimal = 0

    /// Months with nothing stopped at the card. The app keeps no payment
    /// history; this is the record it can prove.
    var onTimeMonths: Int {
      max(0, monthsOpen) - min(max(0, blockedCharges), max(0, monthsOpen))
    }
  }

  // The ladder in one place, so the thresholds, the why and the next step can
  // never drift apart.
  static let onTimePointCap = 8
  static let balanceBands: [Decimal] = [2_000, 8_000, 25_000]
  static let savingsBands: [Decimal] = [
    Decimal(string: "0.2")!, Decimal(string: "0.5")!, Decimal(string: "0.8")!,
  ]
  static let openBands: [Decimal] = [6, 18, 36]
  static let steadyAt = 5
  static let primeAt = 11

  struct Assessment: Equatable, Sendable {
    /// One fact, the value the app holds, and what it contributed.
    struct Reason: Equatable, Sendable {
      var fact: String
      var detail: String
      var points: Int
    }

    /// The next single action, not a list: the first fact that can still earn
    /// a point, in the order a person can act on it.
    struct Step: Equatable, Sendable {
      var fact: String
      var action: String
    }

    var tier: CapacityTier
    var points: Int
    var reasons: [Reason]
    var step: Step?

    /// What the next tier needs and the one step that moves toward it. The
    /// chat answer and the document print the same sentence.
    var nextLine: String {
      guard let next = tier.next else {
        return "Prime is the top tier; the facts above are what hold it."
      }
      let missing = next.threshold - points
      let need = "\(next.name) needs \(missing) more point\(missing == 1 ? "" : "s")"
      guard let step else { return need + "." }
      return "\(need). The next single step: \(step.action)."
    }
  }

  /// The facts as the app holds them, assembled in one place: the opening
  /// date, the person's funds, the charges stopped at the card, and the
  /// balance the ledger reports. A missing date is a new account, not a guess.
  static func facts(
    now: Date = Date(),
    accountOpenedAt: Date?,
    goals: [Goal],
    blockedCharges: Int,
    balance: Money,
    calendar: Calendar = .current
  ) -> Facts {
    let months = accountOpenedAt.map { opened in
      max(0, calendar.dateComponents([.month], from: opened, to: now).month ?? 0)
    } ?? 0
    // Progress per fund, then averaged: two currencies are never summed.
    let ratios = goals.compactMap { goal -> Decimal? in
      guard goal.targetMinor > 0 else { return nil }
      return min(1, Decimal(max(0, goal.savedMinor)) / Decimal(goal.targetMinor))
    }
    let kept = ratios.isEmpty ? Decimal(0) : ratios.reduce(0, +) / Decimal(ratios.count)
    return Facts(
      monthsOpen: months,
      blockedCharges: max(0, blockedCharges),
      averageBalance: balance,
      savingsKept: kept)
  }

  /// The tier for these facts, and the arithmetic that decided it.
  static func tier(for facts: Facts) -> Assessment {
    let open = max(0, facts.monthsOpen)
    let stopped = max(0, facts.blockedCharges)
    let onTime = facts.onTimeMonths

    let timePoints = min(onTime, onTimePointCap)
    let balancePoints = band(facts.averageBalance.majorUnits, balanceBands)
    let savingsPoints = band(max(0, facts.savingsKept), savingsBands)
    let openPoints = band(Decimal(open), openBands)

    let stoppedDetail = stopped == 0
      ? "nothing stopped at the card"
      : "\(stopped) charge\(stopped == 1 ? "" : "s") stopped at the card"
    let reasons: [Assessment.Reason] = [
      Assessment.Reason(
        fact: "On-time months",
        detail: "\(onTime) of \(open) months open, \(stoppedDetail)",
        points: timePoints),
      Assessment.Reason(
        fact: "Balance held",
        detail: "\(facts.averageBalance.display) usually held",
        points: balancePoints),
      Assessment.Reason(
        fact: "Funds kept",
        detail: "\(percentLabel(facts.savingsKept)) of the funds' targets",
        points: savingsPoints),
      Assessment.Reason(
        fact: "Account open",
        detail: "\(open) months since it opened",
        points: openPoints),
    ]
    let points = reasons.reduce(0) { $0 + $1.points }
    let tier: CapacityTier = points >= primeAt ? .prime : (points >= steadyAt ? .steady : .base)
    return Assessment(
      tier: tier,
      points: points,
      reasons: reasons,
      step: nextStep(
        facts: facts, timePoints: timePoints, balancePoints: balancePoints,
        savingsPoints: savingsPoints, openPoints: openPoints, tier: tier))
  }

  /// The next single action: the fund first (it can move today), then the
  /// balance, then the months that accrue with behaviour, then the age that
  /// arrives on its own. Only one is named, because only one is next.
  private static func nextStep(
    facts: Facts, timePoints: Int, balancePoints: Int, savingsPoints: Int, openPoints: Int,
    tier: CapacityTier
  ) -> Assessment.Step? {
    guard tier.next != nil else { return nil }
    if savingsPoints < savingsBands.count {
      return Assessment.Step(
        fact: "Funds kept",
        action: "the funds are \(percentLabel(facts.savingsKept)) of their targets — "
          + "\(percentLabel(savingsBands[savingsPoints])) earns the point")
    }
    if balancePoints < balanceBands.count {
      let need = Money(majorUnits: balanceBands[balancePoints], currency: facts.averageBalance.currency)
      return Assessment.Step(
        fact: "Balance held", action: "hold \(need.display) through the month and the point is yours")
    }
    if timePoints < onTimePointCap {
      return Assessment.Step(
        fact: "On-time months", action: "one more month with nothing stopped at the card adds a point")
    }
    if openPoints < openBands.count {
      let target = NSDecimalNumber(decimal: openBands[openPoints]).intValue
      let remaining = target - max(0, facts.monthsOpen)
      return Assessment.Step(
        fact: "Account open",
        action: "the account reaches \(target) months in \(remaining) more; the point arrives with it")
    }
    return nil
  }

  /// How many of the bands a value has met.
  static func band(_ value: Decimal, _ bands: [Decimal]) -> Int {
    bands.filter { value >= $0 }.count
  }

  /// A progress ratio as a whole percent, rounded down: half kept is 50%, and
  /// 49.9% is not 50%.
  static func percentLabel(_ ratio: Decimal) -> String {
    var value = min(1, max(0, ratio)) * 100
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 0, .down)
    return "\(NSDecimalNumber(decimal: rounded).intValue)%"
  }
}
