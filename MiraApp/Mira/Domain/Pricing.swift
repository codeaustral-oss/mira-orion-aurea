import Foundation

// MARK: - FX

enum FXError: Error, Equatable {
  case nonPositiveRate
  case unknownRateDirection
}

/// Asset conversion with an explicit direction, an explicit rate and an
/// explicit rounding strategy. Nothing about a conversion is implicit.
enum FX {
  /// Converts `amount` using a rate expressed as **quote units per one base unit**.
  ///
  /// For the Mira fixture the direction is `1 USD = 5.0000 BRL`, so converting
  /// BRL 150.00 back into USD divides by 5.
  static func convert(
    amount: Money,
    rate: Decimal,
    rateDirection: RateDirection,
    rounding: RoundingStrategy
  ) throws -> Money {
    guard rate > 0 else { throw FXError.nonPositiveRate }

    switch rateDirection {
    case .quotePerBase(let base, let quote):
      if amount.currency == quote {
        let major = amount.majorUnits / rate
        return Money(majorUnits: major, currency: base, rounding: rounding)
      } else if amount.currency == base {
        let major = amount.majorUnits * rate
        return Money(majorUnits: major, currency: quote, rounding: rounding)
      } else {
        throw FXError.unknownRateDirection
      }
    }
  }
}

/// Direction of a quoted rate. Stored explicitly because "the rate" is
/// meaningless without it, and getting it backwards silently inverts a price.
enum RateDirection: Hashable, Sendable, Codable {
  case quotePerBase(base: Asset, quote: Asset)

  var base: Asset {
    switch self {
    case .quotePerBase(let base, _): return base
    }
  }

  var quote: Asset {
    switch self {
    case .quotePerBase(_, let quote): return quote
    }
  }

  /// "1 USD = 5.0000 BRL"
  func label(rate: Decimal) -> String {
    "1 \(base.code) = \(DecimalFormatting.plain(rate, scale: 4)) \(quote.code)"
  }
}

enum DecimalFormatting {
  static func plain(_ value: Decimal, scale: Int) -> String {
    var input = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &input, scale, .plain)
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.decimalSeparator = "."
    formatter.minimumFractionDigits = scale
    formatter.maximumFractionDigits = scale
    return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "0"
  }
}

// MARK: - Quote

enum QuoteStatus: Equatable, Sendable {
  case active
  case expired

  var label: String {
    switch self {
    case .active: return "Active"
    case .expired: return "Expired"
    }
  }
}

/// An immutable, time-boxed price for a specific payment.
///
/// Approval binds to this exact quote: any material change invalidates the
/// approval rather than silently re-pricing.
struct FXQuote: Identifiable, Hashable, Sendable, Codable {
  let id: UUID
  let direction: RateDirection
  let rate: Decimal
  /// What the recipient receives, in the destination currency.
  let recipientAmount: Money
  /// The converted amount debited, excluding the fee.
  let conversionDebit: Money
  let fee: Money
  let issuedAt: Date
  /// Demo lifetime. Clearly labelled as simulated in the UI.
  let lifetime: TimeInterval
  let rounding: RoundingStrategy
  let sourceAccountId: String

  init(
    id: UUID = UUID(),
    direction: RateDirection,
    rate: Decimal,
    recipientAmount: Money,
    conversionDebit: Money,
    fee: Money,
    issuedAt: Date,
    lifetime: TimeInterval,
    rounding: RoundingStrategy = .bankers,
    sourceAccountId: String = "usd.cleared"
  ) {
    self.id = id
    self.direction = direction
    self.rate = rate
    self.recipientAmount = recipientAmount
    self.conversionDebit = conversionDebit
    self.fee = fee
    self.issuedAt = issuedAt
    self.lifetime = lifetime
    self.rounding = rounding
    self.sourceAccountId = sourceAccountId
  }

  var totalDebit: Money { conversionDebit + fee }

  var expiresAt: Date { issuedAt.addingTimeInterval(lifetime) }

  func status(at now: Date) -> QuoteStatus {
    now >= expiresAt ? .expired : .active
  }

  func isExpired(at now: Date) -> Bool {
    status(at: now) == .expired
  }

  var rateLabel: String { direction.label(rate: rate) }

  /// Seconds remaining, floored at zero, for the countdown ring.
  func secondsRemaining(at now: Date) -> TimeInterval {
    max(0, expiresAt.timeIntervalSince(now))
  }

  /// 1.0 at issue, 0.0 at expiry.
  func fractionRemaining(at now: Date) -> Double {
    guard lifetime > 0 else { return 0 }
    return max(0, min(1, secondsRemaining(at: now) / lifetime))
  }

  /// The all-in cost, stated as the user experiences it.
  var allInSummary: String {
    "\(recipientAmount.display) to the recipient · \(totalDebit.display) total debit"
  }
}

// MARK: - Quote factory (demo pricing)

/// The simulated pricing provider. Every number here is made up for
/// demonstration and must be labelled as such in the UI. It is deliberately not
/// a market feed.
struct SimulatedQuoteProvider: Sendable {
  /// The fixture from the brief: 1 USD = 5.0000 BRL.
  var rate: Decimal
  var feeUSD: Money
  /// A configured demo interval, not a real pricing window.
  var lifetime: TimeInterval
  let rounding: RoundingStrategy
  let sourceAccountId: String

  /// The configured demo interval.
  ///
  /// The brief requires the quote lifetime to be a configured, clearly labelled
  /// demonstration value rather than a hard-coded constant, so it can be set per
  /// environment: a short window to show expiry on stage, a long one for an
  /// automated run that cannot afford to race a clock.
  static var configuredLifetime: TimeInterval {
    guard let raw = ProcessInfo.processInfo.environment["MIRA_QUOTE_LIFETIME"],
      let value = TimeInterval(raw), value > 0
    else { return 120 }
    return value
  }

  init(
    rate: Decimal = 5.0000,
    feeUSD: Money = Money(minorUnits: 30, currency: .usd),
    lifetime: TimeInterval = SimulatedQuoteProvider.configuredLifetime,
    rounding: RoundingStrategy = .bankers,
    sourceAccountId: String = "usd.cleared"
  ) {
    self.rate = rate
    self.feeUSD = feeUSD
    self.lifetime = lifetime
    self.rounding = rounding
    self.sourceAccountId = sourceAccountId
  }

  static let briefFixture = SimulatedQuoteProvider()

  func quote(forRecipientAmount amount: Money, now: Date = Date()) throws -> FXQuote {
    let direction = RateDirection.quotePerBase(base: .usd, quote: .brl)
    let debit = try FX.convert(
      amount: amount,
      rate: rate,
      rateDirection: direction,
      rounding: rounding
    )
    return FXQuote(
      direction: direction,
      rate: rate,
      recipientAmount: amount,
      conversionDebit: debit,
      fee: feeUSD,
      issuedAt: now,
      lifetime: lifetime,
      rounding: rounding,
      sourceAccountId: sourceAccountId
    )
  }
}
