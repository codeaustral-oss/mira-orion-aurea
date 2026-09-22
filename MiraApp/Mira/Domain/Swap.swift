import Foundation

// MARK: - Rates

/// A simulated rate table.
///
/// Everything is quoted against one USD base, which is how a real multi-asset
/// product works and is also the only way to keep cross rates consistent: a
/// direct USD→USDC rate and a USD→BRL→USDC route must not disagree.
///
/// These are demonstration figures. USDT is deliberately shown a hair below
/// parity because a stablecoin that is always exactly 1.0000 is a fiction, and
/// the interface should be able to show a small depeg honestly.
struct RateTable: Sendable {
  /// Units of the asset per one USD.
  private let perUSD: [String: Decimal]
  /// When these rates were fetched, and where from. A reference table has no
  /// timestamp: it is the table that ships with the build.
  var asOf: Date?
  var source: String

  init(
    perUSD: [String: Decimal] = RateTable.demo,
    asOf: Date? = nil,
    source: String = "reference"
  ) {
    self.perUSD = perUSD
    self.asOf = asOf
    self.source = source
  }

  /// The table the app prices with right now: the live one when it has been
  /// fetched recently, the shipped reference table otherwise. The session
  /// refreshes it in the background; a quote always says which one it used.
  static var current = RateTable(perUSD: RateTable.demo, asOf: nil, source: "reference")

  static let demo: [String: Decimal] = [
    "USD": 1,
    "USDC": 1,
    "USDT": 0.9998,
    "BRL": 5.0000,
    "EUR": 0.9200,
    "GBP": 0.7900,
  ]

  /// Units of `asset` per one USD.
  func rate(for asset: Asset) -> Decimal? {
    perUSD[asset.code]
  }

  /// How many units of `to` one unit of `from` buys.
  func cross(from: Asset, to: Asset) -> Decimal? {
    guard let f = rate(for: from), let t = rate(for: to), f > 0 else { return nil }
    return t / f
  }

  /// Live means it was fetched, from somewhere other than the build.
  var isLive: Bool { source != "reference" && asOf != nil }

  /// "live 12:13" — the age of a rate, said the way a person says it. Nil for
  /// the reference table, which is not pretending to be timely.
  var ageLabel: String? {
    guard let asOf, isLive else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return "live \(formatter.string(from: asOf))"
  }
}

// MARK: - Swap quote

/// An immutable, time-boxed price for one asset conversion.
struct SwapQuote: Identifiable, Hashable, Sendable, Codable {
  let id: UUID
  let from: Asset
  let to: Asset
  /// Units of `to` per one unit of `from`.
  let rate: Decimal
  /// What leaves the source, before the fee.
  let fromAmount: Money
  /// What the fee costs, denominated in the source asset.
  let fee: Money
  let toAmount: Money
  let issuedAt: Date
  let lifetime: TimeInterval
  let rounding: RoundingStrategy

  init(
    id: UUID = UUID(),
    from: Asset,
    to: Asset,
    rate: Decimal,
    fromAmount: Money,
    fee: Money,
    toAmount: Money,
    issuedAt: Date,
    lifetime: TimeInterval,
    rounding: RoundingStrategy = .bankers
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.rate = rate
    self.fromAmount = fromAmount
    self.fee = fee
    self.toAmount = toAmount
    self.issuedAt = issuedAt
    self.lifetime = lifetime
    self.rounding = rounding
  }

  var totalDebit: Money { fromAmount + fee }
  var expiresAt: Date { issuedAt.addingTimeInterval(lifetime) }
  func isExpired(at now: Date) -> Bool { now >= expiresAt }
  func secondsRemaining(at now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

  /// "1 USD = 1.000000 USDC" — written with the destination asset's own
  /// precision, so a six-decimal token does not get displayed at two.
  var rateLabel: String {
    // Four places is a rate a person can read and check; six is the token's
    // precision, which belongs in the arithmetic rather than on the screen.
    let scale = min(max(to.decimals, 2), 4)
    return "1 \(from.code) = \(DecimalFormatting.plain(rate, scale: scale)) \(to.code)"
  }
}

// MARK: - Quote factory

struct SimulatedSwapProvider: Sendable {
  var table: RateTable
  /// A flat fee in the source asset, in that asset's major units.
  var feeMajorUnits: Decimal
  var lifetime: TimeInterval
  let rounding: RoundingStrategy

  init(
    table: RateTable = RateTable(),
    feeMajorUnits: Decimal = Decimal(string: "0.25")!,
    lifetime: TimeInterval = SimulatedQuoteProvider.configuredLifetime,
    rounding: RoundingStrategy = .bankers
  ) {
    self.table = table
    self.feeMajorUnits = feeMajorUnits
    self.lifetime = lifetime
    self.rounding = rounding
  }

  static let demo = SimulatedSwapProvider()

  func quote(from: Asset, to: Asset, amount: Money, now: Date = Date()) throws -> SwapQuote {
    guard from != to else { throw SwapError.sameAsset }
    guard amount.currency == from else { throw SwapError.assetMismatch }
    guard amount.minorUnits > 0 else { throw SwapError.nonPositiveAmount }
    guard let rate = table.cross(from: from, to: to) else { throw SwapError.noRate(from.code) }

    // Fee is taken in the source asset at that asset's precision.
    let fee = Money(majorUnits: feeMajorUnits, currency: from, rounding: rounding)

    // Convert at the destination asset's own precision. This is the only place
    // a rounding decision is made, and it is stated on the quote.
    let converted = Money(
      majorUnits: amount.majorUnits * rate,
      currency: to,
      rounding: rounding
    )

    return SwapQuote(
      from: from,
      to: to,
      rate: rate,
      fromAmount: amount,
      fee: fee,
      toAmount: converted,
      issuedAt: now,
      lifetime: lifetime,
      rounding: rounding
    )
  }
}

enum SwapError: Error, Equatable {
  case sameAsset
  case assetMismatch
  case nonPositiveAmount
  case noRate(String)
}

// MARK: - Swap record

struct Swap: Identifiable, Hashable, Sendable {
  let id: UUID
  var quote: SwapQuote
  var approval: PaymentApproval?
  var state: PaymentState
  var idempotencyKey: String
  var history: [StateTransition]

  init(quote: SwapQuote, now: Date = Date()) {
    self.id = quote.id
    self.quote = quote
    self.approval = nil
    self.state = .draft
    self.idempotencyKey = "swap:\(quote.id.uuidString)"
    self.history = [StateTransition(at: now, from: .draft, to: .draft, note: "Quote issued")]
  }

  /// The material fields of the quote. Changing any of them must invalidate an
  /// approval, exactly as it does for a payment.
  var fingerprint: String {
    let material = [
      quote.from.code, quote.to.code, "\(quote.rate)",
      "\(quote.fromAmount.minorUnits)", "\(quote.fee.minorUnits)", "\(quote.toAmount.minorUnits)",
      quote.expiresAt.timeIntervalSince1970.description,
    ].joined(separator: "|")
    return material
  }

  mutating func approve(consentId: String, at now: Date, userGesture: Bool) throws {
    guard case .draft = state else {
      throw PaymentTransitionError.invalidTransition(from: state.label, to: "Approved")
    }
    approval = PaymentApproval(
      draftFingerprint: fingerprint, quoteId: quote.id, approvedAt: now, consentId: consentId,
      wasUserGesture: userGesture)
    let previous = state
    state = .settled(providerReference: "internal", settledAt: now)
    history.append(
      StateTransition(at: now, from: previous, to: state, note: "Swap approved and executed"))
  }
}

// MARK: - Posting

extension Ledger {
  /// Posts a swap.
  ///
  /// Two balanced movements in two assets, tied together by explicit clearing
  /// postings. The book must balance per asset, so a conversion can never
  /// create or destroy value in either leg.
  @discardableResult
  func postSwap(_ quote: SwapQuote, idempotencyKey: String, memo: String, at date: Date) throws
    -> Bool
  {
    let fromAccount = Ledger.accountId(for: quote.from)
    let toAccount = Ledger.accountId(for: quote.to)
    let fromClearing =
      quote.from == .usd ? "fx.clearing" : "fx.clearing.\(quote.from.code.lowercased())"
    let toClearing = quote.to == .usd ? "fx.clearing" : "fx.clearing.\(quote.to.code.lowercased())"
    let feeAccount = "fees.\(quote.from.code.lowercased())"

    return try post(
      JournalEntry(
        idempotencyKey: idempotencyKey,
        date: date,
        memo: memo,
        references: EntryReferences(providerReference: nil, consentId: idempotencyKey),
        postings: [
          Posting(
            accountId: fromAccount,
            amount: Money(minorUnits: -quote.totalDebit.minorUnits, currency: quote.from)),
          Posting(accountId: feeAccount, amount: quote.fee),
          Posting(accountId: fromClearing, amount: quote.fromAmount),
          Posting(
            accountId: toClearing,
            amount: Money(minorUnits: -quote.toAmount.minorUnits, currency: quote.to)),
          Posting(accountId: toAccount, amount: quote.toAmount),
        ]
      )
    )
  }
}
