import Foundation

// MARK: - Asset

/// A unit of value with its own precision.
///
/// Fiat and stablecoins are both assets here, and they differ in one way that
/// matters to the arithmetic: precision. USDC and USDT carry six decimals, so
/// `minorUnitScale` is the thing that keeps them correct. Amounts stay integer
/// minor units at that asset's own scale — a token amount is never approximated
/// into cents, and a dollar amount is never carried at six places it cannot have.
struct Asset: Hashable, Sendable, Codable, Identifiable {
  enum Kind: String, Hashable, Sendable, Codable {
    case fiat
    /// A token that tracks a fiat value. Deliberately separate from `fiat`:
    /// holding USDC is not the same as holding a bank deposit, and the interface
    /// must never conflate them.
    case stablecoin
  }

  let code: String
  let minorUnitScale: Int
  let symbol: String
  let name: String
  let kind: Kind

  var id: String { code }

  init(code: String, minorUnitScale: Int, symbol: String, name: String, kind: Kind = .fiat) {
    self.code = code
    self.minorUnitScale = minorUnitScale
    self.symbol = symbol
    self.name = name
    self.kind = kind
  }

  /// Places of precision, for display and for the swap maths.
  var decimals: Int { minorUnitScale }

  static let usd = Asset(code: "USD", minorUnitScale: 2, symbol: "US$", name: "US Dollar")
  static let brl = Asset(code: "BRL", minorUnitScale: 2, symbol: "R$", name: "Brazilian Real")
  static let eur = Asset(code: "EUR", minorUnitScale: 2, symbol: "€", name: "Euro")
  /// Quoted by the rate sources and by the proxy's corridor table. The app
  /// carries it as an asset so a GBP question prices with the same table
  /// instead of falling through to a model.
  static let gbp = Asset(code: "GBP", minorUnitScale: 2, symbol: "£", name: "British Pound")

  /// Six decimals, as the token actually has.
  static let usdc = Asset(
    code: "USDC", minorUnitScale: 6, symbol: "USDC", name: "USD Coin", kind: .stablecoin)
  static let usdt = Asset(
    code: "USDT", minorUnitScale: 6, symbol: "USDT", name: "Tether USD", kind: .stablecoin)

  static let all: [Asset] = [.usd, .brl, .eur, .gbp, .usdc, .usdt]
  static let fiat: [Asset] = [.usd, .brl, .eur, .gbp]
  static let stablecoins: [Asset] = [.usdc, .usdt]
}

// MARK: - Rounding

/// Explicit rounding policy for FX. Never rely on a framework default silently.
enum RoundingStrategy: String, Sendable, Codable {
  /// Rounds half to even. Avoids the upward bias of "half away from zero"
  /// accumulating across many small conversions.
  case bankers
  /// Rounds half away from zero. Familiar to most people reading a receipt.
  case plain

  var decimalMode: Decimal.RoundingMode {
    switch self {
    case .bankers: return .bankers
    case .plain: return .plain
    }
  }
}

// MARK: - Money

/// An exact fiat amount in integer minor units.
struct Money: Hashable, Sendable, Codable, Comparable {
  var minorUnits: Int64
  var currency: Asset

  init(minorUnits: Int64, currency: Asset) {
    self.minorUnits = minorUnits
    self.currency = currency
  }

  static func zero(_ currency: Asset) -> Money {
    Money(minorUnits: 0, currency: currency)
  }

  /// Builds an amount from a decimal in major units, rounding to the
  /// currency's minor-unit scale with the given strategy.
  init(majorUnits: Decimal, currency: Asset, rounding: RoundingStrategy = .bankers) {
    let scaled = majorUnits * pow(Decimal(10), currency.minorUnitScale)
    var input = scaled
    var rounded = Decimal()
    NSDecimalRound(&rounded, &input, 0, rounding.decimalMode)
    self.minorUnits = NSDecimalNumber(decimal: rounded).int64Value
    self.currency = currency
  }

  var majorUnits: Decimal {
    Decimal(minorUnits) / pow(Decimal(10), currency.minorUnitScale)
  }

  var isZero: Bool { minorUnits == 0 }
  var isNegative: Bool { minorUnits < 0 }

  var magnitude: Money {
    Money(minorUnits: abs(minorUnits), currency: currency)
  }

  // MARK: Arithmetic
  //
  // All arithmetic is currency-checked. Mixing currencies is a programmer
  // error, not something to paper over at runtime: FX must be explicit.

  static func + (lhs: Money, rhs: Money) -> Money {
    precondition(
      lhs.currency == rhs.currency,
      "cannot add \(lhs.currency.code) and \(rhs.currency.code) without an explicit conversion"
    )
    return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency)
  }

  static func - (lhs: Money, rhs: Money) -> Money {
    precondition(
      lhs.currency == rhs.currency,
      "cannot subtract \(lhs.currency.code) and \(rhs.currency.code) without an explicit conversion"
    )
    return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currency: lhs.currency)
  }

  static func * (lhs: Money, rhs: Int) -> Money {
    Money(minorUnits: lhs.minorUnits * Int64(rhs), currency: lhs.currency)
  }

  static func < (lhs: Money, rhs: Money) -> Bool {
    precondition(
      lhs.currency == rhs.currency, "cannot compare \(lhs.currency.code) and \(rhs.currency.code)")
    return lhs.minorUnits < rhs.minorUnits
  }

  /// Applies a decimal multiplier (for example a fee rate) and rounds back
  /// into minor units with an explicit strategy.
  func multiplied(by factor: Decimal, rounding: RoundingStrategy = .bankers) -> Money {
    Money(majorUnits: majorUnits * factor, currency: currency, rounding: rounding)
  }
}

// MARK: - Formatting

extension Money {
  /// Always renders the currency code. The brief forbids relying on an
  /// ambiguous "$": USD and BRL must be unambiguous at a glance.
  var display: String {
    MoneyFormatter.display(self)
  }

  /// Signed form for ledger deltas.
  var signedDisplay: String {
    let sign = minorUnits > 0 ? "+" : (minorUnits < 0 ? "−" : "")
    return sign + magnitude.display
  }
}

enum MoneyFormatter {
  private static func makeFormatter(min: Int, max: Int) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    f.decimalSeparator = "."
    f.minimumFractionDigits = min
    f.maximumFractionDigits = max
    return f
  }

  /// How many fraction digits to actually show for an asset.
  ///
  /// A token carries six decimals because it has to, not because anyone wants to
  /// read them. USDC 1,250.400000 is noise; USDC 1,250.40 is an amount. So the
  /// trailing zeros are trimmed, but never past the asset's own precision and
  /// never below two places, so a column of figures still lines up.
  private static func fractionRange(for asset: Asset, minorUnits: Int64) -> (min: Int, max: Int) {
    guard asset.kind == .stablecoin else {
      return (asset.minorUnitScale, asset.minorUnitScale)
    }
    let limit = asset.minorUnitScale
    var divisor: Int64 = 1
    var trailing = 0
    while trailing < limit - 2, minorUnits % (divisor * 10) == 0 {
      divisor *= 10
      trailing += 1
    }
    return (2, limit - trailing)
  }

  static func display(_ money: Money) -> String {
    let negative = money.minorUnits < 0
    let magnitude = money.magnitude
    let range = fractionRange(for: magnitude.currency, minorUnits: magnitude.minorUnits)
    let formatter = makeFormatter(min: range.min, max: range.max)
    let number = NSDecimalNumber(decimal: magnitude.majorUnits)
    let body = formatter.string(from: number) ?? "0"
    return "\(negative ? "−" : "")\(magnitude.currency.code) \(body)"
  }

  /// The bare figure, without the asset code. Used where the code is already on
  /// screen, so "USD" is never printed twice in one block.
  static func amount(_ money: Money) -> String {
    let magnitude = money.magnitude
    let range = fractionRange(for: magnitude.currency, minorUnits: magnitude.minorUnits)
    let formatter = makeFormatter(min: range.min, max: range.max)
    let number = NSDecimalNumber(decimal: magnitude.majorUnits)
    return formatter.string(from: number) ?? "0"
  }

  /// Compact form for dense rows: "USD 4,000" when there are no minor units.
  static func compact(_ money: Money) -> String {
    if money.currency.minorUnitScale == 2, money.minorUnits % 100 == 0 {
      let whole = money.minorUnits / 100
      let f = NumberFormatter()
      f.numberStyle = .decimal
      f.groupingSeparator = ","
      let body = f.string(from: NSNumber(value: whole)) ?? "0"
      return "\(money.currency.code) \(body)"
    }
    return display(money)
  }
}
