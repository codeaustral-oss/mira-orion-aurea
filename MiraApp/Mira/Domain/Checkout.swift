import Foundation

// MARK: - Buying something, with an agent
//
// A purchase is a conversation with state: where it goes, which address to keep,
// which card pays, and one last yes. The stages are plain data, the reading of
// answers is plain functions — so nothing here depends on a model's opinion of a
// sentence — and the movement at the end is the app's own simulated ledger. In a
// demo bank the debit is as real as every other figure in it; the last step is
// the platform's, and it is labelled as such where it matters.

/// A delivery address the person saved, so it is never typed twice.
struct Address: Codable, Sendable, Equatable, Identifiable {
  var id: UUID = UUID()
  var text: String
  var isMain: Bool = false
  var addedAt: Date = Date()
}

enum CheckoutStage: String, Sendable {
  /// Where should it go?
  case place
  /// Shall this be the main delivery address?
  case confirmMainAddress
  /// Which card pays?
  case payment
  /// One last look, then place it.
  case confirm
}

struct CheckoutDraft: Sendable {
  var item: String
  var merchant: String?
  var amount: Money?
  var address: Address?
  var card: CardMock?
  /// A virtual card made for this order, when the person asked for one.
  var virtualCard: CardMock?
  /// Set when the person overrode a protected goal for this order.
  var goalOverride: Bool = false
  var stage: CheckoutStage
}

/// The reading behind the checkout conversation. Pure and testable on purpose.
enum CheckoutFlow {
  enum PaymentChoice: Sendable { case mainCard, virtualCard, useVirtualCard }

  /// "buy the Brooks Ghost 15", "order the Nike ones", "i'll take the Pegasus".
  /// A decision to buy — not "find me …", which is research.
  static func namedPurchaseItem(in message: String) -> String? {
    let text = trimmed(message)
    let patterns = [
      "^(?:please\\s+)?(?:buy|order|purchase|get me|grab)\\s+(?:the\\s+|a\\s+|an\\s+)?(.{2,80})$",
      "^i(?:'ll| will)?\\s+(?:take|buy|order|get)\\s+(?:the\\s+|a\\s+|an\\s+)?(.{2,80})$",
      "^(?:get|take)\\s+(?:the\\s+|a\\s+|an\\s+)?(.{2,80})$",
    ]
    for pattern in patterns {
      guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
      else { continue }
      let phrase = String(text[match]).replacingOccurrences(
        of: pattern, with: "$1", options: [.regularExpression, .caseInsensitive])
      let cleaned = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
      // "buy it" and "order that" are context, not a name; "buy something else"
      // is an intention, not an item.
      if cleaned.count >= 2, !isContextReference(cleaned), !isFillerItem(cleaned) { return cleaned }
    }
    return nil
  }

  /// "buy it", "order it", "i'll take it" — buy the thing we were just showing.
  static func isContextPurchase(_ message: String) -> Bool {
    let text = trimmed(message)
    if namedPurchaseItem(in: text) != nil { return false }
    return text.range(
      of: "^(?:please\\s+)?(?:buy|order|purchase|take|get)\\s+(?:it|that|this|those|them)$",
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// "something else", "anything", "a new one" — a wish, not a thing to buy.
  static func isFillerItem(_ phrase: String) -> Bool {
    let lowered = phrase.lowercased()
    let fillers: Set<String> = ["something", "anything", "something else", "anything else",
                                "nothing", "a new one", "another one", "more"]
    return fillers.contains(lowered)
  }

  static func isContextReference(_ phrase: String) -> Bool {
    ["it", "that", "this", "those", "them", "one", "the one"].contains(phrase.lowercased())
  }

  /// A place, typed the way people type places: one to five words, no verb, no
  /// question. "Florianópolis, Brazil" is a place; "where is my card" is not.
  static func placeAnswer(_ message: String) -> String? {
    let text = trimmed(message)
    guard !text.isEmpty, text.count <= 60, !text.contains("?") else { return nil }
    if StandaloneAgent.isAffirmative(text) || StandaloneAgent.isNegative(text) { return nil }
    let words = text.split(separator: " ").map(String.init)
    guard words.count <= 5 else { return nil }
    let verbs: Set<String> = [
      "want", "need", "send", "pay", "use", "buy", "order", "find", "show", "cancel", "check",
      "change", "swap", "exchange", "help", "give",
    ]
    if words.contains(where: { verbs.contains($0.lowercased()) }) { return nil }
    guard text.range(of: "^[A-Za-zÀ-ÿ0-9'’,. -]+$", options: .regularExpression) != nil else { return nil }
    return text
  }

  /// "Use my main address" — the chip that skips typing a place again.
  static func wantsMainAddressAnswer(_ message: String) -> Bool {
    let text = trimmed(message).lowercased()
    return text.contains("main address") && !text.contains("make it")
  }

  /// "yes, make it main" / "no, just this once".
  static func mainAddressAnswer(_ message: String) -> Bool? {
    if StandaloneAgent.isAffirmative(message) { return true }
    if StandaloneAgent.isNegative(message) { return false }
    let text = trimmed(message).lowercased()
    if text.contains("make it main") || text.contains("main address") || text.contains("default") {
      return true
    }
    if text.contains("just this once") || text.contains("one time") { return false }
    return nil
  }

  /// Which card to pay with. The person's words, not a menu index.
  static func paymentChoice(_ message: String) -> PaymentChoice? {
    let text = trimmed(message).lowercased()
    if text.contains("virtual") { return text.contains("use ") ? .useVirtualCard : .virtualCard }
    if text.contains("new card") { return .virtualCard }
    if text.contains("this card") || text.contains("main card") || text.contains("my card")
      || text.contains("use the card") || text.contains("default")
    {
      return .mainCard
    }
    return nil
  }

  /// "place the order" / "cancel".
  static func placeOrderAnswer(_ message: String) -> Bool? {
    let text = trimmed(message).lowercased()
    if text.contains("place") && (text.contains("order") || text.contains("it")) { return true }
    if StandaloneAgent.isAffirmative(message) { return true }
    if StandaloneAgent.isNegative(message) { return false }
    return nil
  }

  /// A price note written by a page ("USD 99.95", "EUR 89") as money.
  static func amount(from priceNote: String?) -> Money? {
    guard let priceNote else { return nil }
    let match = priceNote.range(
      of: "(USD|US\\$|EUR|€|BRL|R\\$)\\s?([0-9]+(?:[.,][0-9]{1,2})?)",
      options: [.regularExpression, .caseInsensitive])
    guard let match else { return nil }
    let text = String(priceNote[match])
    let asset: Asset
    if text.contains("US$") || text.uppercased().contains("USD") {
      asset = .usd
    } else if text.contains("€") || text.uppercased().contains("EUR") {
      asset = .eur
    } else {
      asset = .brl
    }
    let digits = text.replacingOccurrences(
      of: "[^0-9.,]", with: "", options: .regularExpression)
      .replacingOccurrences(of: ",", with: ".")
    guard let value = Decimal(string: digits) else { return nil }
    return Money(majorUnits: value, currency: asset)
  }

  /// A price the app already has for an item: the first priced option on a
  /// recent completed shopping task about it. "buy cat food" after researching
  /// cat food uses the page's own price, so the receipt states an amount
  /// instead of leaving the charge blank. No match, no guess: nil.
  static func knownPick(
    for item: String, in tasks: [AgentTask]
  ) -> (name: String, merchant: String?, amount: Money)? {
    let needle = item.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nil }
    let candidates = tasks
      .filter { $0.kind == "shopping" && $0.status == .completed }
      .sorted { $0.updatedAt > $1.updatedAt }
    for task in candidates {
      let subjects = [task.slots["product"], task.title, task.summary]
        .compactMap { $0?.lowercased() }
      guard subjects.contains(where: { $0.contains(needle) }) else { continue }
      for option in task.options {
        guard let amount = amount(from: option.priceNote) else { continue }
        let merchant = option.url.flatMap {
          URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "")
        }
        return (option.name, merchant, amount)
      }
    }
    return nil
  }

  /// A virtual card for one order: its own number, its own limit, named for
  /// what it is for. The number is generated here because this is a demo bank —
  /// a real product issues it at the issuer and the app only ever holds a token.
  static func virtualCard(for merchant: String?, holder: String) -> CardMock {
    func group() -> String { String(format: "%04d", Int.random(in: 0...9999)) }
    let expiry: String = {
      let calendar = Calendar(identifier: .gregorian)
      let date = calendar.date(byAdding: .year, value: 3, to: Date()) ?? Date()
      let formatter = DateFormatter()
      formatter.dateFormat = "MM/yy"
      return formatter.string(from: date)
    }()
    return CardMock(
      id: "card-virtual-\(UUID().uuidString.prefix(8))",
      nickname: "Virtual · \(merchant ?? "this order")",
      holder: holder,
      pan: "5199 \(group()) \(group()) \(group())",
      expiry: expiry,
      cvv: String(format: "%03d", Int.random(in: 0...999)),
      network: .visa,
      kind: .credit,
      frozen: false
    )
  }

  private static func trimmed(_ message: String) -> String {
    message.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
