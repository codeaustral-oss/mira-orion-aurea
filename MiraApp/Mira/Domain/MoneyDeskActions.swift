import Foundation

// MARK: - The money desk, part two
//
// These five end in a *prepared action*: the agent does the noticing, the
// arithmetic and the paperwork, shows exactly what it would send or file, and
// waits for one word. Nothing here moves money on its own.

// MARK: 1 · Price-drop retro-claims

/// Something bought, at a price, with the window the price can fall inside.
struct PriceClaim: Identifiable, Codable, Sendable, Equatable {
  enum Stage: String, Codable, Sendable {
    case watching
    case claimPrepared
    case filed
    case expired
  }

  var id: UUID = UUID()
  var item: String
  var merchant: String?
  var paidMinor: Int64
  var currencyCode: String
  var purchasedAt: Date
  var windowDays: Int = 30
  var stage: Stage = .watching
  /// What the price fell to, once the app is told or finds out.
  var currentMinor: Int64?
  var claimMinor: Int64?
  var reference: String?

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var paid: Money { Money(minorUnits: paidMinor, currency: currency) }
  var claim: Money? { claimMinor.map { Money(minorUnits: $0, currency: currency) } }

  func windowEnd(calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: .day, value: windowDays, to: purchasedAt) ?? purchasedAt
  }

  func daysLeft(now: Date = Date(), calendar: Calendar = .current) -> Int {
    max(0, calendar.dateComponents([.day], from: now, to: windowEnd(calendar: calendar)).day ?? 0)
  }
}

/// What the agent would send, and to whom, before anything is filed.
struct ClaimPreparation: Sendable, Equatable {
  var claim: PriceClaim
  var difference: Money
  var deadline: String
  var steps: [String]

  var summary: String {
    "\(difference.display) back on \(claim.item) — inside the \(claim.windowDays)-day window."
  }
}

enum PriceClaims {
  /// The difference, when the price really fell.
  static func difference(paid: Money, now: Money) -> Money? {
    let drop = paid.minorUnits - now.minorUnits
    guard drop > 0, paid.currency == now.currency else { return nil }
    return Money(minorUnits: drop, currency: paid.currency)
  }

  static func prepare(_ claim: PriceClaim, current: Money, now: Date = Date()) -> ClaimPreparation? {
    guard let difference = difference(paid: claim.paid, now: current) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMMM"
    var prepared = claim
    prepared.stage = .claimPrepared
    prepared.currentMinor = current.minorUnits
    prepared.claimMinor = difference.minorUnits
    return ClaimPreparation(
      claim: prepared,
      difference: difference,
      deadline: formatter.string(from: claim.windowEnd()),
      steps: [
        "Open the order in \(claim.merchant ?? "the store") and choose the price-match or return request.",
        "Attach the receipt — it is already in this conversation.",
        "Ask for \(difference.display); the window closes \(formatter.string(from: claim.windowEnd())).",
      ])
  }

  static func open(_ claims: [PriceClaim], now: Date = Date()) -> [PriceClaim] {
    claims.filter { $0.stage == .watching || $0.stage == .claimPrepared }
      .sorted { $0.daysLeft(now: now) < $1.daysLeft(now: now) }
  }
}

// MARK: 4 · Bill negotiation at renewal

/// A bill with a renewal date and a competitor's offer to hold it against.
struct NegotiableBill: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var name: String
  var monthlyMinor: Int64
  var currencyCode: String
  var renewalInDays: Int
  var competitor: String
  var competitorMonthlyMinor: Int64

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var monthly: Money { Money(minorUnits: monthlyMinor, currency: currency) }
  var competitorMonthly: Money { Money(minorUnits: competitorMonthlyMinor, currency: currency) }
}

enum Negotiation {
  struct Ask: Sendable, Equatable {
    var bill: NegotiableBill
    var target: Money
    var yearlySaving: Money
    var script: [String]
    var deadline: String
  }

  /// The ask: hold the price to the competitor's, or lose the account — with
  /// the number that makes it credible and the day it has to happen.
  static func prepare(_ bill: NegotiableBill, now: Date = Date()) -> Ask {
    let target = Money(
      minorUnits: min(bill.monthlyMinor, bill.competitorMonthlyMinor), currency: bill.currency)
    let saving = Money(
      minorUnits: (bill.monthlyMinor - target.minorUnits) * 12, currency: bill.currency)
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMMM"
    let when = Calendar.current.date(byAdding: .day, value: bill.renewalInDays, to: now) ?? now
    return Ask(
      bill: bill,
      target: target,
      yearlySaving: saving,
      script: [
        "I've been with you for a while and I'd like to stay.",
        "\(bill.competitor) is offering me \(bill.competitorMonthly.display) a month.",
        "Can you match \(target.display)? Otherwise I'll switch at renewal.",
        "If there's a retention team, this is a good moment to pass me through.",
      ],
      deadline: formatter.string(from: when))
  }

  /// The line after "They said yes" / "They said no". The ask was shown in the
  /// same turn, so the outcome is recorded against it — and nothing claims a
  /// price change the app has not seen in a statement.
  static func outcome(_ ask: Ask?, accepted: Bool) -> String {
    guard let ask else {
      return accepted
        ? "Recorded — tell me the bill and the price they agreed and I'll keep it on the next statement."
        : "Noted — nothing changed."
    }
    if accepted {
      return "Recorded — \(ask.bill.name) at \(ask.target.display) when it renews \(ask.deadline). "
        + "I'll check the next statement says the same; tell me if they counter."
    }
    return "Then switch at renewal; I'll have \(ask.bill.competitor)'s link ready."
  }
}

// MARK: 7 · Claims, prepared for the person

/// Something that happened, and what the person is owed for it.
struct ClaimCase: Identifiable, Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable {
    case flightDelay
    case travelDelay
    case damagedDelivery
    case refundOverdue

    var label: String {
      switch self {
      case .flightDelay: return "Flight delay"
      case .travelDelay: return "Travel delay"
      case .damagedDelivery: return "Damaged delivery"
      case .refundOverdue: return "Refund overdue"
      }
    }
  }

  var id: UUID = UUID()
  var kind: Kind
  var subject: String
  var at: Date = Date()
  var distanceKm: Int?
  var currencyCode: String = "EUR"
  var amountMinor: Int64?
  var documents: [String] = []
  var stage: String = "prepared"
  var reference: String?

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .eur }
}

enum Claims {
  /// Air-passenger compensation bands, by distance — the rule most claims turn
  /// on, and the part people get wrong.
  static func flightCompensation(distanceKm: Int, currencyCode: String = "EUR") -> Money? {
    switch distanceKm {
    case ..<1: return nil
    case ..<1500: return Money(minorUnits: 25_000, currency: Asset.all.first { $0.code == currencyCode } ?? .eur)
    case ..<3500: return Money(minorUnits: 40_000, currency: Asset.all.first { $0.code == currencyCode } ?? .eur)
    default: return Money(minorUnits: 60_000, currency: Asset.all.first { $0.code == currencyCode } ?? .eur)
    }
  }

  static func prepare(_ kind: ClaimCase.Kind, subject: String, distanceKm: Int? = nil) -> ClaimCase {
    var documents: [String]
    var amount: Money?
    switch kind {
    case .flightDelay, .travelDelay:
      documents = ["boarding pass", "booking confirmation", "airline's delay notice"]
      if let distanceKm { amount = flightCompensation(distanceKm: distanceKm) }
    case .damagedDelivery:
      documents = ["order confirmation", "photo of the damage", "the delivery note"]
    case .refundOverdue:
      documents = ["receipt", "the store's refund promise", "your bank statement line"]
    }
    return ClaimCase(
      kind: kind, subject: subject, distanceKm: distanceKm,
      amountMinor: amount?.minorUnits, documents: documents)
  }
}

// MARK: 8 · Agent budgets

/// A sub-agent with a monthly limit: this is what "agents spending money" needs
/// before anyone is comfortable with it — a number, a period, and receipts.
struct AgentBudget: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var agent: String
  var limitMinor: Int64
  var spentMinor: Int64 = 0
  var currencyCode: String
  var receipts: [String] = []

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var limit: Money { Money(minorUnits: limitMinor, currency: currency) }
  var spent: Money { Money(minorUnits: spentMinor, currency: currency) }
  var remaining: Money { Money(minorUnits: max(0, limitMinor - spentMinor), currency: currency) }

  func canSpend(_ amount: Money) -> Bool {
    amount.currency == currency && amount.minorUnits <= remaining.minorUnits
  }
}

// MARK: 9 · Goals, with guards

/// Money that is not to be touched without an explicit override.
///
/// A goal is a record the person owns, so the three fields the piggy-banks
/// screen needs beyond the arithmetic — the art it shows, the line the person
/// wrote about it, and when it was made — live on the record itself. An older
/// file simply does not carry them, which is why decoding is lenient: a goal
/// saved before the piggy banks existed must still open.
struct Goal: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var name: String
  var targetMinor: Int64
  var savedMinor: Int64
  var currencyCode: String
  var protected: Bool = true
  /// The catalog asset for this dream, when one exists. Nil means the art is
  /// either a live image cached under the goal's id, or nothing at all.
  var artAsset: String?
  /// The person's own line about the dream. Shown in the detail sheet.
  var story: String?
  var createdAt: Date = Date()

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var target: Money { Money(minorUnits: targetMinor, currency: currency) }
  var saved: Money { Money(minorUnits: savedMinor, currency: currency) }
  var remaining: Money { Money(minorUnits: max(0, targetMinor - savedMinor), currency: currency) }
}

extension Goal {
  /// Declared because both halves of Codable are written by hand here, so the
  /// compiler does not synthesize the key list for us.
  enum CodingKeys: String, CodingKey {
    case id, name, targetMinor, savedMinor, currencyCode, protected
    case artAsset, story, createdAt
  }

  /// Lenient on purpose, the same way the directory payload is: a goal written
  /// by an earlier build has no `artAsset`, `story` or `createdAt`, and a
  /// missing key must read as a default rather than make the file unreadable.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
    name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Goal"
    targetMinor = ((try? c.decodeIfPresent(Int64.self, forKey: .targetMinor)) ?? nil) ?? 0
    savedMinor = ((try? c.decodeIfPresent(Int64.self, forKey: .savedMinor)) ?? nil) ?? 0
    currencyCode = ((try? c.decodeIfPresent(String.self, forKey: .currencyCode)) ?? nil) ?? "USD"
    protected = ((try? c.decodeIfPresent(Bool.self, forKey: .protected)) ?? nil) ?? true
    artAsset = (try? c.decodeIfPresent(String.self, forKey: .artAsset)) ?? nil
    story = (try? c.decodeIfPresent(String.self, forKey: .story)) ?? nil
    createdAt = ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil) ?? Date()
  }

  /// Explicit, so the lenient reader above is the only custom half and the
  /// written shape stays the plain one.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(targetMinor, forKey: .targetMinor)
    try c.encode(savedMinor, forKey: .savedMinor)
    try c.encode(currencyCode, forKey: .currencyCode)
    try c.encode(protected, forKey: .protected)
    try c.encodeIfPresent(artAsset, forKey: .artAsset)
    try c.encodeIfPresent(story, forKey: .story)
    try c.encode(createdAt, forKey: .createdAt)
  }
}

enum GoalGuard {
  /// A purchase that is large against a protected goal says so in plain words,
  /// and needs an override before it proceeds. The check is the app's own
  /// arithmetic on figures it holds — no model decides what is "too big".
  static func warning(
    purchase: Money,
    goals: [Goal],
    threshold: Decimal = Decimal(string: "0.25")!
  ) -> (goal: Goal, line: String)? {
    guard let goal = goals.first(where: { $0.protected && $0.currency == purchase.currency }),
      goal.savedMinor > 0
    else { return nil }
    let share = Decimal(purchase.minorUnits) / Decimal(goal.savedMinor)
    guard share >= threshold else { return nil }
    return (
      goal,
      "This is a big one: \(purchase.display) is a large part of the \(goal.saved.display) you set aside for \(goal.name). Place it anyway?"
    )
  }
}
