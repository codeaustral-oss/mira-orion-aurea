import Foundation

// MARK: - Near-live rates
//
// A rate is a fact with a timestamp. The app prices swaps with the live table
// when it can get one — through the proxy first, then from a public source
// directly, because the phone has no proxy when it is out — and with the table
// that ships in the build when it cannot. A quote always says which one it used.
//
// This is deliberately small: one fetch, one cache, no retries in a loop. A
// failed refresh changes nothing: the previous table (live or reference) stays,
// and a stale live table is never presented as if it were new.

enum LiveRates {
  /// How long a fetched table stays "current" before another fetch is worth it.
  static let ttl: TimeInterval = 90

  private(set) static var lastAttempt: Date?

  /// Refresh `RateTable.current` if the current one is missing, stale or a
  /// reference table. Safe to call often: it is a no-op inside the TTL.
  @discardableResult
  static func refresh(baseURL: URL?) async -> RateTable {
    if RateTable.current.isLive,
      let asOf = RateTable.current.asOf,
      Date().timeIntervalSince(asOf) < ttl
    {
      return RateTable.current
    }
    lastAttempt = Date()

    if let baseURL, let proxied = await fromProxy(baseURL: baseURL) {
      RateTable.current = proxied
      return proxied
    }
    if let direct = await fromPublicSource() {
      RateTable.current = direct
      return direct
    }
    return RateTable.current
  }

  /// The proxy caches for a minute and knows the same sources the server does.
  /// This call carries the proxy key when the installed bundle has one.
  private static func fromProxy(baseURL: URL) async -> RateTable? {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/fx"))
    request.timeoutInterval = 6
    do {
      let (data, response) = try await URLSession.miraProxy.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        root["ok"] as? Bool == true,
        let perUSD = root["perUSD"] as? [String: Any]
      else { return nil }
      return table(from: perUSD, source: (root["source"] as? String) ?? "proxy", asOf: Date())
    } catch {
      return nil
    }
  }

  /// Coinbase's public spot endpoint, called directly: fiat and stablecoins.
  /// Deliberately on `.shared`: a public source must never see the proxy key.
  private static func fromPublicSource() async -> RateTable? {
    var request = URLRequest(url: URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!)
    request.timeoutInterval = 6
    request.setValue("application/json", forHTTPHeaderField: "accept")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let dataBlock = root["data"] as? [String: Any],
        let rates = dataBlock["rates"] as? [String: Any]
      else { return nil }
      return table(from: rates, source: "coinbase", asOf: Date())
    } catch {
      return nil
    }
  }

  /// Build a table from a `code → units per USD` map, keeping the stablecoin
  /// par defaults when a source does not carry them.
  static func table(from wire: [String: Any], source: String, asOf: Date) -> RateTable? {
    var perUSD: [String: Decimal] = ["USD": 1]
    for code in ["EUR", "BRL", "GBP"] {
      if let value = wire[code], let number = decimal(from: value), number > 0 {
        perUSD[code] = number
      }
    }
    for code in Asset.all.map(\.code) where perUSD[code] == nil {
      if let value = wire[code], let number = decimal(from: value), number > 0 {
        perUSD[code] = number
      }
    }
    if perUSD["USDC"] == nil { perUSD["USDC"] = 1 }
    if perUSD["USDT"] == nil { perUSD["USDT"] = Decimal(string: "0.9998") }
    // One fiat pair at least: anything else means the source answered garbage.
    guard perUSD["EUR"] != nil || perUSD["BRL"] != nil else { return nil }
    return RateTable(perUSD: perUSD, asOf: asOf, source: source)
  }

  private static func decimal(from value: Any) -> Decimal? {
    if let text = value as? String { return Decimal(string: text) }
    if let number = value as? Double { return Decimal(number) }
    if let number = value as? Int { return Decimal(number) }
    return nil
  }
}
