import Foundation

// MARK: - The app's half of the consent policy
//
// The server reads a message with Jev and says what it carries; these rules
// decide what to do about it, and they are mirrored here so the app behaves the
// same with no proxy at all. The shape of the policy:
//
//   · observe  — never asks. A balance, a rate, a search, a watch's check.
//   · prepare  — never asks to prepare; asks only for a detail that is
//                genuinely absent, and never for one the app already holds.
//   · commit   — one person's step. Given in the message ("buy it now"), or by
//                standing approval, or by one final confirmation.

/// What the proxy read from a message. Every field optional: a failed read is
/// simply not a reading.
struct ConsentRead: Sendable {
  var ok: Bool
  var authorises: Double?
  var suppliesDetail: Double?
  var missing: String?
  var risk: String?
  var decision: String?
  var detail: String?

  init(
    ok: Bool,
    authorises: Double? = nil,
    suppliesDetail: Double? = nil,
    missing: String? = nil,
    risk: String? = nil,
    decision: String? = nil,
    detail: String? = nil
  ) {
    self.ok = ok
    self.authorises = authorises
    self.suppliesDetail = suppliesDetail
    self.missing = missing
    self.risk = risk
    self.decision = decision
    self.detail = detail
  }
}

enum ConsentDecision: Equatable {
  case proceed
  case confirm
  case ask(String)
}

enum ConsentPolicy {
  /// A standing approval covers ordinary amounts and stops at this one. Above
  /// it, a person looks, even when they said "always".
  static let standingLimit = Money(majorUnits: 250, currency: .usd)

  /// The same decisions the server makes, so a phone with no proxy behaves
  /// identically rather than more freely.
  static func decision(from read: ConsentRead, known: Set<String>) -> ConsentDecision {
    guard read.ok else { return .confirm }
    if let missing = read.missing, missing != "none", !known.contains(missing) {
      if (read.suppliesDetail ?? 0) < 0.5 { return .ask(missing) }
    }
    if read.risk == "high" { return .confirm }
    if let authorises = read.authorises, authorises >= 0.5 { return .proceed }
    switch read.decision {
    case "proceed": return .proceed
    case "ask": return .ask(read.detail ?? "detail")
    default: return .confirm
    }
  }

  /// A message that might carry its own authorisation — where asking the typed
  /// read is worth the round trip. Everything else just runs the staged flow.
  static func looksAuthorising(_ message: String) -> Bool {
    let text = message.lowercased()
    let markers = [
      "now", "just do it", "go ahead", "right away", "immediately", "don't ask", "dont ask",
      "and place", "and pay", "and buy", "place it", "agora", "ya",
    ]
    return markers.contains { text.contains($0) }
  }

  /// Standing approval: a repeat of the same shape, under the limit. The amount
  /// has to be known — a cap that cannot be checked is not a cap, so an order
  /// with no price still gets its one confirmation.
  static func standingCovers(amount: Money?, standing: Bool) -> Bool {
    guard standing, let amount else { return false }
    return amount.majorUnits <= standingLimit.majorUnits
  }
}
