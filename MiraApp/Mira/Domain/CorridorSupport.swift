import Foundation

// MARK: - The corridors this build actually quotes
//
// The app mirror of `server/lib/corridor-support.mjs`: one list, both sides of
// the wire. A question about money in a currency the build does not price used
// to end anywhere — a transfer prompt, a research task, a model paragraph that
// guessed. The honest answer needs the list, and it has to be the same list the
// rate table uses.
//
// A corridor is priceable when both currencies are quoted. Everything is quoted
// against one USD base, so a pair with no direct corridor (EUR → BRL, say) is
// still a priced cross through USD — the arithmetic `RateTable.cross` already
// does. A currency outside the quoted set has no rate at all, and the answer
// says so instead of inventing one.

enum CorridorSupport {
  /// The currencies a quote can be made in. The app's `Asset` table carries the
  /// same codes.
  static let quotedCurrencies: [String] = ["USD", "BRL", "EUR", "GBP", "USDC", "USDT"]

  /// The directed pairs the product sells: USD/BRL, BRL/USD, USD/EUR, EUR/USD,
  /// GBP/USD, USD/USDC and USD/USDT, with the inverse of every pair whose
  /// inverse is not already listed.
  static let directPairs: [(from: String, to: String)] = [
    ("USD", "BRL"),
    ("BRL", "USD"),
    ("USD", "EUR"),
    ("EUR", "USD"),
    ("GBP", "USD"),
    ("USD", "GBP"),
    ("USD", "USDC"),
    ("USDC", "USD"),
    ("USD", "USDT"),
    ("USDT", "USD"),
  ]

  static func isQuoted(_ code: String) -> Bool {
    quotedCurrencies.contains(code.uppercased())
  }

  /// True when a rate can be quoted for the pair — directly, or through USD.
  static func supports(from: Asset, to: Asset) -> Bool {
    from != to && isQuoted(from.code) && isQuoted(to.code)
  }

  static func supports(fromCode: String, toCode: String) -> Bool {
    let from = fromCode.uppercased()
    let to = toCode.uppercased()
    return from != to && isQuoted(from) && isQuoted(to)
  }

  /// "USD/BRL, BRL/USD, …" — the pairs as the product states them.
  static var quotedPairsPhrase: String {
    directPairs.map { "\($0.from)/\($0.to)" }.joined(separator: ", ")
  }

  /// "USD, BRL, EUR, GBP, USDC and USDT".
  static var quotedCurrenciesPhrase: String {
    guard let last = quotedCurrencies.last else { return "" }
    return quotedCurrencies.dropLast().joined(separator: ", ") + " and " + last
  }

  /// Currency markers the build does not quote, and the words people use for
  /// them. Codes, plus the words that name one currency unambiguously: a bare
  /// "peso" does not say whether the answer is MXN or ARS, so it is not matched
  /// on its own.
  private static let unquotedMarkers: [(code: String, words: [String])] = [
    ("MXN", ["mxn", "mexican peso", "mexican pesos", "pesos mexicanos"]),
    ("ARS", ["ars", "argentine peso", "argentine pesos", "peso argentino", "pesos argentinos"]),
    ("NGN", ["ngn", "naira", "nairas"]),
    ("INR", ["inr", "rupee", "rupees", "rupia", "rupias"]),
    ("JPY", ["jpy", "yen"]),
    ("CNY", ["cny", "yuan", "renminbi"]),
    ("ZAR", ["zar", "rand"]),
    ("CLP", ["clp", "chilean peso", "chilean pesos"]),
    ("COP", ["cop", "colombian peso", "colombian pesos"]),
    ("PEN", ["pen", "sol", "soles"]),
    ("TRY", ["try", "lira", "liras"]),
    ("AED", ["aed", "dirham", "dirhams"]),
    ("THB", ["thb", "baht"]),
    ("CHF", ["chf", "swiss franc", "swiss francs"]),
    ("AUD", ["aud", "australian dollar", "australian dollars"]),
    ("CAD", ["cad", "canadian dollar", "canadian dollars"]),
    ("NZD", ["nzd", "new zealand dollar", "new zealand dollars"]),
    ("SEK", ["sek", "swedish krona", "swedish kronor"]),
    ("NOK", ["nok", "norwegian krone", "norwegian kroner"]),
    ("DKK", ["dkk", "danish krone", "danish kroner"]),
    ("PLN", ["pln", "zloty", "złoty"]),
    ("SGD", ["sgd", "singapore dollar", "singapore dollars"]),
    ("HKD", ["hkd", "hong kong dollar", "hong kong dollars"]),
    ("KRW", ["krw", "won"]),
    ("ILS", ["ils", "shekel", "shekels"]),
  ]

  static var unquotedCodes: [String] { unquotedMarkers.map(\.code) }

  /// The first unquoted currency named in the message, or nil.
  static func unquotedCurrency(in text: String) -> String? {
    let lowered = text.lowercased()
    for marker in unquotedMarkers {
      if marker.words.contains(where: { lowered.contains($0) }) { return marker.code }
    }
    return nil
  }

  /// The words that make a message about money rather than, say, a country.
  private static let moneyContext =
    #"\b(convert|converting|exchange|change|changing|swap|price|pricing|quote|rate|send|sending|receive|receiving|payout|pay out|pay|paid|transfer|hold|holding|deposit|withdraw|buy|sell|get|give|gives|corridor|balance|worth|cost|costs|approximate|estimate|figures?|number)\b"#

  /// A question about money in a currency this build cannot price, or nil.
  /// Narrow on purpose: "Argentina" is a country question and is left to the
  /// model; "NGN payout" is a corridor question and gets the honest answer.
  static func corridorQuestion(in message: String) -> String? {
    guard let code = unquotedCurrency(in: message) else { return nil }
    guard message.range(of: moneyContext, options: [.regularExpression, .caseInsensitive]) != nil else {
      return nil
    }
    return code
  }

  /// The deterministic answer for a corridor the build cannot price. It names
  /// the currency that cannot be quoted, then exactly what can, and nothing
  /// else — never a transfer prompt, never a research request.
  static func answer(for code: String) -> String {
    "\(code) is not a corridor this build prices. I can quote \(quotedPairsPhrase) — "
      + "any pair among \(quotedCurrenciesPhrase) — and I won't invent a rate for anything else."
  }
}
