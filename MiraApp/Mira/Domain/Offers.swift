import Foundation

// MARK: - Offers
//
// We are the issuer, so cashback is not "which of your cards pays more". It is
// an offer engine, and the variables are the ones an issuer actually sets:
//
//   · **where**  — a merchant category (pet, dining, groceries, online), one
//     named merchant, or everything;
//   · **when**   — days of the week, a time window, an expiry date;
//   · **how**    — in person or online, a minimum spend, a per-month cap;
//   · **who pays** — merchant-funded (Petz pays for its own offer) or
//     issuer-funded (we buy the behaviour);
//   · **why**    — the behaviour it is meant to move: a new category, a lapsed
//     cardholder, a habit worth growing.
//
// The cardholder's agent evaluates all of that *before* the payment: is the
// offer live now, does this purchase qualify, what is left of the cap this
// month, and what does it expect back. The issuer's side sees what it cost and
// what it moved. Neither side invents a rate: the terms are data, the decision
// is arithmetic.

enum OfferScope: Codable, Sendable, Equatable {
  case everything
  case category(String)
  case merchant(String)

  var label: String {
    switch self {
    case .everything: return "Everything"
    case .category(let name): return name.capitalized
    case .merchant(let name): return name
    }
  }
}

enum OfferChannel: String, Codable, Sendable, CaseIterable {
  case any
  case online
  case inPerson

  var label: String {
    switch self {
    case .any: return "Anywhere"
    case .online: return "Online"
    case .inPerson: return "In person"
    }
  }
}

enum OfferFunding: Codable, Sendable, Equatable {
  case issuer
  /// The merchant funds it — the usual shape of a category offer.
  case merchant(String)

  var label: String {
    switch self {
    case .issuer: return "Mira-funded"
    case .merchant(let name): return "\(name)-funded"
    }
  }
}

/// One offer, as it would be written on the issuer's side.
struct CardOffer: Identifiable, Codable, Sendable, Equatable {
  var id: String
  var title: String
  var rate: Decimal
  var scope: OfferScope
  var channel: OfferChannel = .any
  /// Days it runs: 1 = Sunday … 7 = Saturday. Nil means every day.
  var days: [Int]?
  var minimumSpendMinor: Int64?
  /// The most one cardholder can earn from it in a month.
  var capMinor: Int64?
  var funding: OfferFunding
  var currencyCode: String
  var expiresAt: Date?

  var ratePercent: String {
    let percent = NSDecimalNumber(decimal: rate * 100).doubleValue
    return percent == percent.rounded() ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
  }

  func runsOn(_ date: Date, calendar: Calendar = .current) -> Bool {
    guard let days, !days.isEmpty else { return true }
    // Calendar weekday: 1 = Sunday, matching the stored days.
    return days.contains(calendar.component(.weekday, from: date))
  }

  func matches(scope target: OfferScope) -> Bool {
    switch (scope, target) {
    case (.everything, _): return true
    case (.category(let mine), .category(let theirs)): return mine.caseInsensitiveCompare(theirs) == .orderedSame
    case (.category(let mine), .merchant(let theirs)): return theirs.lowercased().contains(mine.lowercased())
    case (.merchant(let mine), .merchant(let theirs)): return mine.caseInsensitiveCompare(theirs) == .orderedSame
    case (.merchant(let mine), .category(let theirs)): return mine.lowercased().contains(theirs.lowercased())
    default: return false
    }
  }
}

/// Money that came back, with the receipt's own facts.
struct CashbackEntry: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var offerID: String
  var offerTitle: String
  var cardLast4: String
  var merchant: String
  var item: String
  var category: String = "everything"
  var amountMinor: Int64
  var currencyCode: String
  var earnedMinor: Int64
  var ratePercent: String
  var at: Date = Date()
  var credited: Bool = false

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var earned: Money { Money(minorUnits: earnedMinor, currency: currency) }
  var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
}

/// What the engine decided for one purchase, and why.
struct OfferDecision: Sendable, Equatable {
  var offer: CardOffer
  var expected: Money
  /// Set when the month's cap stops the return short.
  var cappedAt: Money?
  /// Why the other offers did not apply — the reason, stated.
  var passedOver: [String]

  var line: String {
    var text = "\(offer.ratePercent) back — about \(expected.display) (\(offer.funding.label))"
    if let cappedAt { text += " · cap reached at \(cappedAt.display) this month" }
    return text
  }
}

enum Offers {
  /// The offers running this month, written the way an issuer writes them.
  static func running(now: Date = Date()) -> [CardOffer] {
    let calendar = Calendar.current
    func daysFromNow(_ days: Int) -> Date {
      calendar.date(byAdding: .day, value: days, to: now) ?? now
    }
    return [
      CardOffer(
        id: "pet-weekend",
        title: "5% back at pet shops, weekends",
        rate: Decimal(string: "0.05")!,
        scope: .category("pet"),
        channel: .any,
        days: [1, 7], // Sunday and Saturday
        capMinor: 3_000,
        funding: .merchant("Petz"),
        currencyCode: "BRL",
        expiresAt: daysFromNow(21)),
      CardOffer(
        id: "dining-tuesday",
        title: "2× dining on Tuesdays",
        rate: Decimal(string: "0.06")!,
        scope: .category("dining"),
        channel: .inPerson,
        days: [3], // Tuesday
        capMinor: 6_000,
        funding: .issuer,
        currencyCode: "BRL",
        expiresAt: daysFromNow(45)),
      CardOffer(
        id: "online-4",
        title: "4% back online",
        rate: Decimal(string: "0.04")!,
        scope: .category("online"),
        channel: .online,
        days: nil,
        minimumSpendMinor: 5_000,
        capMinor: 8_000,
        funding: .merchant("Amazon"),
        currencyCode: "BRL",
        expiresAt: daysFromNow(12)),
      CardOffer(
        id: "groceries-2",
        title: "2% back on groceries",
        rate: Decimal(string: "0.02")!,
        scope: .category("groceries"),
        channel: .any,
        days: nil,
        capMinor: 4_000,
        funding: .issuer,
        currencyCode: "BRL",
        expiresAt: nil),
      CardOffer(
        id: "base",
        title: "1.5% back everywhere",
        rate: Decimal(string: "0.015")!,
        scope: .everything,
        channel: .any,
        days: nil,
        capMinor: nil,
        funding: .issuer,
        currencyCode: "BRL",
        expiresAt: nil),
    ]
  }

  /// What kind of spend this is, from the words the app already has.
  static func category(for text: String) -> String {
    let lowered = text.lowercased()
    let table: [(String, [String])] = [
      ("pet", ["pet", "petz", "cobasi", "cat", "dog", "gato", "cachorro", "ração", "cat food"]),
      ("dining", ["restaurant", "ifood", "lunch", "dinner", "cafe", "café", "bar", "sushi", "pizza"]),
      ("groceries", ["market", "supermarket", "groceries", "mercado", "hortifruti"]),
      ("online", ["online", "amazon", "shop", "store", "loja", "ecommerce", "web", ".com"]),
    ]
    for (category, words) in table where words.contains(where: { lowered.contains($0) }) {
      return category
    }
    return "everything"
  }

  static func channel(for text: String) -> OfferChannel {
    let lowered = text.lowercased()
    if ["online", "amazon", ".com", "web", "app", "ifood"].contains(where: { lowered.contains($0) }) {
      return .online
    }
    return .inPerson
  }

  /// Evaluate every live offer for one purchase and keep the best that applies.
  ///
  /// The cap is honoured: an offer whose month is used up pays what is left,
  /// and an offer that does not run today is passed over by name — so a person
  /// is told *why* the Tuesday rate is not applying on a Friday.
  static func decide(
    amount: Money,
    purchase: String,
    merchant: String? = nil,
    channel explicitChannel: OfferChannel? = nil,
    entries: [CashbackEntry] = [],
    offers: [CardOffer] = Offers.running(),
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> OfferDecision? {
    let category = category(for: purchase)
    let channel = explicitChannel ?? Offers.channel(for: "\(purchase) \(merchant ?? "")")
    var passed: [String] = []
    var candidates: [(offer: CardOffer, payable: Int64, capped: Money?)] = []

    for offer in offers {
      guard offer.currencyCode == amount.currency.code else { continue }
      if let expiresAt = offer.expiresAt, expiresAt < now {
        passed.append("\(offer.title) — expired")
        continue
      }
      if !offer.runsOn(now, calendar: calendar) {
        passed.append("\(offer.title) — not today")
        continue
      }
      let target: OfferScope = merchant.map { .merchant($0) } ?? .category(category)
      guard offer.matches(scope: target) || (target != .everything && offer.matches(scope: .category(category)))
      else { continue }
      if offer.channel != .any, offer.channel != channel {
        passed.append("\(offer.title) — \(offer.channel.label.lowercased()) only")
        continue
      }
      if let minimum = offer.minimumSpendMinor, amount.minorUnits < minimum {
        passed.append("\(offer.title) — spends under \(Money(minorUnits: minimum, currency: amount.currency).display)")
        continue
      }
      let raw = NSDecimalNumber(decimal: Decimal(amount.minorUnits) * offer.rate).int64Value
      guard raw > 0 else { continue }

      // What the month has already used of this offer's cap.
      let used = entries
        .filter { entry in
          entry.offerID == offer.id && entry.currencyCode == offer.currencyCode
            && calendar.component(.month, from: entry.at) == calendar.component(.month, from: now)
            && calendar.component(.year, from: entry.at) == calendar.component(.year, from: now)
        }
        .reduce(Int64(0)) { $0 + $1.earnedMinor }
      if let cap = offer.capMinor {
        let remaining = max(0, cap - used)
        if remaining == 0 {
          passed.append("\(offer.title) — cap reached")
          continue
        }
        let payable = min(raw, remaining)
        candidates.append((
          offer,
          payable,
          payable < raw ? Money(minorUnits: used, currency: amount.currency) : nil
        ))
      } else {
        candidates.append((offer, raw, nil))
      }
    }

    guard let best = candidates.max(by: { $0.payable < $1.payable }) else { return nil }
    return OfferDecision(
      offer: best.offer,
      expected: Money(minorUnits: best.payable, currency: amount.currency),
      cappedAt: best.capped,
      passedOver: passed)
  }

  /// The offer that applies right now, when the amount is not known yet — the
  /// payment step can still say what this purchase would earn.
  static func applicable(
    purchase: String,
    merchant: String? = nil,
    channel explicitChannel: OfferChannel? = nil,
    offers: [CardOffer] = Offers.running(),
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> CardOffer? {
    let category = category(for: purchase)
    let channel = explicitChannel ?? Offers.channel(for: "\(purchase) \(merchant ?? "")")
    return offers
      .filter { offer in
        if let expiresAt = offer.expiresAt, expiresAt < now { return false }
        guard offer.runsOn(now, calendar: calendar) else { return false }
        let target: OfferScope = merchant.map { .merchant($0) } ?? .category(category)
        let scopeFits = offer.matches(scope: target) || offer.matches(scope: .category(category))
        guard scopeFits else { return false }
        if offer.channel != .any, offer.channel != channel { return false }
        return true
      }
      .max { $0.rate < $1.rate }
  }

  /// The issuer's side: what this month cost, what was redeemed, by whom.
  static func issuerSummary(_ entries: [CashbackEntry], now: Date = Date()) -> (
    cost: Money, merchantFunded: Money, issuerFunded: Money, redemptions: Int, topOffer: String?
  )? {
    guard let currency = entries.first?.currency else { return nil }
    let month = Calendar.current.component(.month, from: now)
    let year = Calendar.current.component(.year, from: now)
    let thisMonth = entries.filter {
      $0.currency == currency
        && Calendar.current.component(.month, from: $0.at) == month
        && Calendar.current.component(.year, from: $0.at) == year
    }
    let funding = Dictionary(grouping: thisMonth, by: { $0.offerID })
    let offers = Offers.running(now: now)
    func isMerchantFunded(_ id: String) -> Bool {
      if case .merchant = offers.first(where: { $0.id == id })?.funding { return true }
      return false
    }
    let total = Money(minorUnits: thisMonth.reduce(Int64(0)) { $0 + $1.earnedMinor }, currency: currency)
    let merchant = Money(
      minorUnits: thisMonth.filter { isMerchantFunded($0.offerID) }.reduce(Int64(0)) { $0 + $1.earnedMinor },
      currency: currency)
    let issuer = Money(
      minorUnits: thisMonth.filter { !isMerchantFunded($0.offerID) }.reduce(Int64(0)) { $0 + $1.earnedMinor },
      currency: currency)
    let top = funding.max { $0.value.reduce(Int64(0)) { $0 + $1.earnedMinor }
      < $1.value.reduce(Int64(0)) { $0 + $1.earnedMinor } }?.value.first?.offerTitle
    return (total, merchant, issuer, thisMonth.count, top)
  }

  /// This month, as the cardholder sees it.
  static func summary(_ entries: [CashbackEntry], now: Date = Date()) -> (
    credited: Money, pending: Money, count: Int, currency: Asset
  )? {
    guard let currency = entries.first?.currency else { return nil }
    let month = Calendar.current.component(.month, from: now)
    let year = Calendar.current.component(.year, from: now)
    let thisMonth = entries.filter {
      $0.currency == currency
        && Calendar.current.component(.month, from: $0.at) == month
        && Calendar.current.component(.year, from: $0.at) == year
    }
    let credited = Money(
      minorUnits: thisMonth.filter(\.credited).reduce(Int64(0)) { $0 + $1.earnedMinor }, currency: currency)
    let pending = Money(
      minorUnits: thisMonth.filter { !$0.credited }.reduce(Int64(0)) { $0 + $1.earnedMinor }, currency: currency)
    return (credited, pending, thisMonth.count, currency)
  }
}
