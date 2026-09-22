import Foundation

// MARK: - Subscriptions
//
// The quietest line in anyone's month: a dozen small charges that add up to a
// number nobody has in their head. This is the app's own record of them — what
// each one costs, when it charges next, and which card pays — so the answer to
// "what can I cancel?" is arithmetic, not a search.
//
// In this demo the list is seeded with a realistic twelve, the way the demo
// account is funded: it is the person's own data as far as every screen is
// concerned, and it can be added to, corrected and cancelled.

struct Subscription: Identifiable, Sendable, Codable, Equatable {
  enum Cadence: String, Codable, Sendable, CaseIterable {
    case monthly
    case yearly

    var label: String { self == .monthly ? "Monthly" : "Yearly" }
    /// How many charges land in a year, and how many months one charge covers.
    var chargesPerYear: Decimal { self == .monthly ? 12 : 1 }
    var monthsPerCharge: Decimal { self == .monthly ? 1 : 12 }
  }

  var id: UUID = UUID()
  var name: String
  var amountMinor: Int64
  var currencyCode: String
  var cadence: Cadence
  /// The day of the month the next charge lands, when the demo knows it.
  var nextChargeDay: Int?
  /// The card it is charged to, by its last four.
  var cardLast4: String?
  var cancelled: Bool = false
  /// The app's own record of last use, in days. Nil when it does not know.
  var lastUsedDaysAgo: Int?

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var amount: Money { Money(minorUnits: amountMinor, currency: currency) }

  /// What a year of this costs — the number that makes a small charge big.
  var yearly: Money {
    let minor = NSDecimalNumber(decimal: Decimal(amountMinor) * cadence.chargesPerYear).int64Value
    return Money(minorUnits: minor, currency: currency)
  }

  /// What a month of this costs: a monthly charge as it is, a yearly charge
  /// spread across the twelve months it covers.
  var monthly: Money {
    let minor = NSDecimalNumber(decimal: Decimal(amountMinor) / cadence.monthsPerCharge).int64Value
    return Money(minorUnits: minor, currency: currency)
  }
}

extension Subscription {
  /// When this charges next, from the day-of-month the record carries. A day
  /// already past this month means next month.
  func nextChargeDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
    guard let day = nextChargeDay else { return nil }
    var components = calendar.dateComponents([.year, .month], from: now)
    components.day = min(max(day, 1), 28)
    components.hour = 12
    guard let candidate = calendar.date(from: components) else { return nil }
    if candidate < calendar.startOfDay(for: now) {
      return calendar.date(byAdding: .month, value: 1, to: candidate)
    }
    return candidate
  }

  /// Does it charge within this many days (today counts as zero)?
  func chargesWithin(days: Int, from now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard let date = nextChargeDate(from: now, calendar: calendar) else { return false }
    let daysAway = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
    ).day ?? 99
    return daysAway >= 0 && daysAway <= days
  }

  /// "in 2 days" / "today" / "tomorrow" — how a person says it.
  func chargeIn(now: Date = Date(), calendar: Calendar = .current) -> String {
    guard let date = nextChargeDate(from: now, calendar: calendar) else { return "soon" }
    let daysAway = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
    ).day ?? 0
    switch daysAway {
    case ...0: return "today"
    case 1: return "tomorrow"
    default: return "in \(daysAway) days"
    }
  }

}

/// What the person could stop paying, and what it would save.
struct SubscriptionSavings: Sendable, Equatable {
  var monthly: Money
  var yearly: Money
  var count: Int
  var cancellable: [Subscription]

  /// The best few to look at, priciest first.
  func top(_ limit: Int = 3) -> [Subscription] {
    Array(cancellable.prefix(limit))
  }

  var yearlyIfCancelled: Money {
    Money(minorUnits: cancellable.reduce(Int64(0)) { $0 + $1.yearly.minorUnits }, currency: monthly.currency)
  }
}

enum Subscriptions {
  /// Twelve small charges, priced the way a Brazilian account would see them.
  /// Every one pays with the card the app actually holds and shows — a charge
  /// is never attributed to a card the person cannot recognise.
  static func demoSeed() -> [Subscription] {
    [
      Subscription(name: "Netflix Standard", amountMinor: 5_990, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 4, cardLast4: "4872"),
      Subscription(name: "Spotify Premium", amountMinor: 2_190, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 9, cardLast4: "4872"),
      Subscription(name: "Amazon Prime", amountMinor: 1_990, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 12, cardLast4: "4872"),
      Subscription(name: "iCloud+ 200 GB", amountMinor: 1_290, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 15, cardLast4: "4872"),
      Subscription(name: "Disney+", amountMinor: 2_799, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 17, cardLast4: "4872"),
      Subscription(name: "Max", amountMinor: 2_990, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 19, cardLast4: "4872", lastUsedDaysAgo: 96),
      Subscription(name: "YouTube Premium", amountMinor: 2_490, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 21, cardLast4: "4872"),
      Subscription(name: "Adobe Creative Cloud", amountMinor: 11_900, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 22, cardLast4: "4872"),
      Subscription(name: "Notion Plus", amountMinor: 4_800, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 24, cardLast4: "4872", lastUsedDaysAgo: 71),
      Subscription(name: "ChatGPT Plus", amountMinor: 10_500, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 26, cardLast4: "4872"),
      Subscription(name: "Smart Fit", amountMinor: 9_990, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 5, cardLast4: "4872"),
      Subscription(name: "iFood Clube", amountMinor: 1_290, currencyCode: "BRL", cadence: .monthly, nextChargeDay: 28, cardLast4: "4872"),
    ]
  }

  /// The card that actually pays a subscription, verified against the cards
  /// this build holds. When a record names a card the app cannot show — an
  /// older seed, a card from another build — the brand's own card is the only
  /// one the person can recognise and the only one a block can honestly name.
  static func payingCard(_ subscription: Subscription, mainCardLast4: String) -> String {
    let record = subscription.cardLast4?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return record == mainCardLast4 ? record : mainCardLast4
  }

  /// The arithmetic behind "what can I cancel?": active items only, in one
  /// currency. Mixed currencies are listed, never summed across a rate the app
  /// does not own.
  static func savings(_ subscriptions: [Subscription]) -> SubscriptionSavings? {
    let active = subscriptions.filter { !$0.cancelled }
    guard let currency = active.first?.currency else { return nil }
    let sameCurrency = active.filter { $0.currency == currency }
    let monthly = Money(
      minorUnits: sameCurrency.reduce(Int64(0)) { $0 + $1.monthly.minorUnits }, currency: currency)
    let yearly = Money(
      minorUnits: sameCurrency.reduce(Int64(0)) { $0 + $1.yearly.minorUnits }, currency: currency)
    let cancellable = sameCurrency.sorted { $0.yearly.minorUnits > $1.yearly.minorUnits }
    return SubscriptionSavings(monthly: monthly, yearly: yearly, count: active.count, cancellable: cancellable)
  }

  /// Next charges, soonest first, for the "what is coming" line.
  static func upcoming(_ subscriptions: [Subscription], limit: Int = 3) -> [Subscription] {
    subscriptions
      .filter { !$0.cancelled && $0.nextChargeDay != nil }
      .sorted { ($0.nextChargeDay ?? 99) < ($1.nextChargeDay ?? 99) }
      .prefix(limit)
      .map { $0 }
  }

  /// The subscriptions charging inside the reminder window, soonest first.
  static func chargingSoon(
    _ subscriptions: [Subscription], days: Int = 3, from now: Date = Date(), calendar: Calendar = .current
  ) -> [Subscription] {
    subscriptions
      .filter { !$0.cancelled && $0.chargesWithin(days: days, from: now, calendar: calendar) }
      .sorted {
        ($0.nextChargeDate(from: now, calendar: calendar) ?? .distantFuture)
          < ($1.nextChargeDate(from: now, calendar: calendar) ?? .distantFuture)
      }
  }

  /// The subscription a sentence is about, by name — "cancel Adobe" finds it.
  static func match(_ text: String, in subscriptions: [Subscription]) -> Subscription? {
    let lowered = text.lowercased()
    return subscriptions.first { subscription in
      let name = subscription.name.lowercased()
      if lowered.contains(name) { return true }
      // A single distinctive word is enough: "cancel Netflix", "drop Smart Fit".
      return name.split(separator: " ").contains { word in
        word.count >= 4 && lowered.contains(word)
      }
    }
  }
}
