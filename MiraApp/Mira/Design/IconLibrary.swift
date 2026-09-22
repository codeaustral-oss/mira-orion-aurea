import SwiftUI
import UIKit

// MARK: - Icons
//
// The icon library is Apple's, and it is already on the phone: SF Symbols is
// several thousand marks deep — finance, investing, technology, travel, health,
// home, transport, nature — and every one of them is a vector that scales and
// adapts to the system. What an app needs on top is not more drawings; it is a
// vocabulary, so that "coffee", "portfolio", "rent" or "server" resolves to the
// right mark, and so does a term nobody anticipated.
//
// Three layers:
//
//   1. **the systems' symbols** — thousands, free, licence-clear, already here;
//   2. **this vocabulary** — a few hundred words a person would actually use,
//      mapped to symbols, with three-step resolution (exact → contained → the
//      category's default);
//   3. **brand marks** — a service or merchant is drawn from its logo by domain
//      (see `ServiceMark`), because no system library carries other companies'
//      trademarks.
//
// Everything resolvable here is verified to exist on the running OS, so a typo
// can never produce a missing frame — the tests check every mapping.

enum Icons {
  /// The vocabulary: a word a person would say, and the mark for it.
  ///
  /// Grouped as the domains this product actually speaks in. The right-hand
  /// side is an SF Symbol name; `symbol(for:)` also accepts a symbol name
  /// directly, so anything in the system library is reachable by name.
  static let vocabulary: [String: String] = [
    // ── Money, accounts, banking ──────────────────────────────────────────
    "money": "banknote", "cash": "banknote.fill", "balance": "banknote",
    "account": "building.columns", "bank": "building.columns.fill",
    "wallet": "wallet.bifold", "card": "creditcard", "credit": "creditcard.fill",
    "debit": "creditcard", "payment": "creditcard.and.123", "pay": "creditcard",
    "send": "paperplane", "receive": "tray.and.arrow.down", "transfer": "arrow.left.arrow.right",
    "pix": "arrow.left.arrow.right.circle", "wire": "arrow.left.arrow.right",
    "fee": "percent", "fees": "percent", "charge": "percent",
    "interest": "percent", "rate": "percent",
    "statement": "doc.text", "receipt": "receipt", "invoice": "doc.plaintext",
    "refund": "arrow.uturn.backward", "chargeback": "arrow.uturn.backward.circle",
    "balance-scale": "scalemass", "budget": "chart.pie", "plan": "list.bullet.rectangle",
    "goal": "flag.checkered", "saving": "banknote", "savings": "banknote",
    "reserve": "shield.lefthalf.filled", "emergency": "cross.case",
    "loan": "hand.raised", "debt": "arrow.down.right.circle", "mortgage": "house",
    "tax": "doc.text.magnifyingglass", "taxes": "doc.text.magnifyingglass",

    // ── Investing and markets ─────────────────────────────────────────────
    "stock": "chart.line.uptrend.xyaxis", "stocks": "chart.line.uptrend.xyaxis",
    "share": "chart.line.uptrend.xyaxis", "shares": "chart.line.uptrend.xyaxis",
    "invest": "chart.line.uptrend.xyaxis", "investment": "chart.line.uptrend.xyaxis",
    "portfolio": "chart.pie.fill", "market": "chart.bar.xaxis",
    "ticker": "chart.line.uptrend.xyaxis", "candle": "chart.bar",
    "dividend": "arrow.down.circle", "yield": "percent",
    "etf": "chart.pie", "fund": "chart.pie", "bond": "doc.text",
    "treasury": "building.columns", "crypto": "bitcoinsign.circle",
    "bitcoin": "bitcoinsign.circle.fill", "ethereum": "diamond",
    "exchange": "arrow.left.arrow.right", "fx": "coloncurrencysign.arrow.circlepath",
    "dollar": "dollarsign.circle", "euro": "eurosign.circle", "real": "brazilianrealsign.circle",
    "pound": "sterlingsign.circle", "yen": "yensign.circle",
    "gold": "circle.hexagongrid", "commodity": "shippingbox",

    // ── Technology ────────────────────────────────────────────────────────
    "tech": "cpu", "server": "server.rack", "cloud": "cloud", "database": "cylinder",
    "data": "cylinder.split.1x2", "storage": "externaldrive", "backup": "externaldrive.badge.timemachine",
    "network": "network", "wifi": "wifi", "signal": "antenna.radiowaves.left.and.right",
    "api": "curlybraces", "code": "chevron.left.forwardslash.chevron.right",
    "terminal": "terminal", "bug": "ladybug", "robot": "cpu", "ai": "sparkles",
    "agent": "cpu", "automation": "gearshape.2", "workflow": "point.3.connected.trianglepath.dotted",
    "device": "iphone", "phone": "iphone", "laptop": "laptopcomputer", "desktop": "desktopcomputer",
    "monitor": "display", "keyboard": "keyboard", "mouse": "computermouse",
    "chip": "memorychip", "gpu": "cpu.fill", "security": "lock.shield",
    "privacy": "hand.raised", "password": "key", "key": "key.fill",
    "encryption": "lock.doc", "firewall": "shield.lefthalf.filled",
    "battery": "battery.100", "power": "bolt", "update": "arrow.triangle.2.circlepath",
    "download": "arrow.down.circle", "upload": "arrow.up.circle",
    "link": "link", "email": "envelope", "message": "message", "chat": "bubble.left.and.bubble.right",
    "notify": "bell", "reminder": "bell.badge", "calendar": "calendar", "clock": "clock",
    "search": "magnifyingglass", "settings": "gearshape", "profile": "person.crop.circle",

    // ── Shopping, merchants, offers ───────────────────────────────────────
    "shop": "bag", "store": "storefront", "cart": "cart", "basket": "basket",
    "order": "shippingbox", "delivery": "truck.box", "tracking": "shippingbox",
    "package": "shippingbox.fill", "gift": "gift", "tag": "tag", "offer": "tag.fill",
    "cashback": "arrow.counterclockwise.circle", "discount": "tag.slash",
    "coupon": "ticket", "loyalty": "star.circle", "points": "star",
    "brand": "sparkles", "subscription": "arrow.triangle.2.circlepath",
    "recurring": "arrow.triangle.2.circlepath.circle", "renewal": "calendar.badge.clock",
    "cancel": "xmark.circle", "unsubscribe": "bell.slash", "zombie": "moon.zzz",

    // ── Travel, transport, places ─────────────────────────────────────────
    "flight": "airplane", "plane": "airplane.departure", "airport": "airplane.arrival",
    "trip": "suitcase", "travel": "suitcase.rolling", "hotel": "bed.double",
    "stay": "house.lodge", "car": "car", "taxi": "car.side", "bus": "bus",
    "train": "tram", "bike": "bicycle", "walk": "figure.walk", "map": "map",
    "location": "location", "address": "mappin.and.ellipse", "globe": "globe",
    "visa": "doc.text.image", "passport": "person.text.rectangle",

    // ── Food, drink, health, home ─────────────────────────────────────────
    "food": "fork.knife", "restaurant": "fork.knife", "lunch": "takeoutbag.and.cup.and.straw",
    "dinner": "wineglass", "coffee": "cup.and.saucer", "drink": "waterbottle",
    "groceries": "cart.badge.plus", "market-food": "basket.fill", "bakery": "birthday.cake",
    "health": "heart", "fitness": "figure.run", "gym": "dumbbell",
    "doctor": "stethoscope", "medicine": "pills", "sleep": "bed.double",
    "home": "house", "rent": "house.fill", "utilities": "bolt.house",
    "water": "drop", "wifi-bill": "wifi", "cleaning": "sparkles",
    "pet": "pawprint", "kids": "figure.child", "education": "graduationcap",
    "book": "book", "music": "music.note", "film": "film", "game": "gamecontroller",
    "sport": "sportscourt", "nature": "leaf", "weather": "cloud.sun",
    "sun": "sun.max", "rain": "cloud.rain", "snow": "snowflake",

    // ── Statuses and states ───────────────────────────────────────────────
    "done": "checkmark.circle", "success": "checkmark.seal", "pending": "clock.badge",
    "waiting": "hourglass", "failed": "exclamationmark.triangle", "error": "xmark.octagon",
    "warning": "exclamationmark.triangle", "info": "info.circle", "help": "questionmark.circle",
    "blocked": "nosign", "frozen": "snowflake", "active": "checkmark.circle.fill",
    "paused": "pause.circle", "expired": "calendar.badge.exclamationmark",
    "verified": "checkmark.shield", "protected": "lock.shield.fill",
    "new": "sparkle", "trending": "chart.line.uptrend.xyaxis", "falling": "chart.line.downtrend.xyaxis",
    "increase": "arrow.up.right", "decrease": "arrow.down.right",
    "fast": "hare", "slow": "tortoise", "urgent": "exclamationmark.bubble",
    "star": "star.fill", "favourite": "heart.fill", "flag": "flag",
    "person": "person", "people": "person.2", "family": "figure.2.and.child.holdinghands",
    "company": "building.2", "government": "building.columns", "law": "text.book.closed",
    "contract": "doc.text.below.ecg", "signature": "signature", "stamp": "seal",
  ]

  /// Resolve a word — or a symbol name — to a symbol that exists here.
  ///
  /// Exact match first, then any vocabulary key contained in the request, then
  /// the request itself if the system knows it, then a neutral mark. A
  /// resolution never returns something the OS cannot draw.
  static func symbol(for request: String) -> String {
    let wanted = request
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    guard !wanted.isEmpty else { return fallback }

    if let exact = vocabulary[wanted], exists(exact) { return exact }
    if exists(wanted) { return wanted } // a symbol name passed through
    for (word, symbol) in vocabulary where wanted.contains(word) && exists(symbol) {
      return symbol
    }
    return fallback
  }

  /// The vocabulary grouped for a picker or a gallery.
  static func words(in category: Category) -> [String] {
    vocabulary.keys.filter { category.matches($0) }.sorted()
  }

  enum Category: String, CaseIterable, Sendable {
    case money, investing, technology, shopping, travel, life, status

    func matches(_ word: String) -> Bool {
      switch self {
      case .money:
        return [
          "money", "cash", "balance", "account", "bank", "wallet", "card", "credit", "debit",
          "payment", "pay", "send", "receive", "transfer", "pix", "wire", "fee", "fees", "charge",
          "interest", "rate", "statement", "receipt", "invoice", "refund", "chargeback", "budget",
          "plan", "goal", "saving", "savings", "reserve", "emergency", "loan", "debt", "mortgage",
          "tax", "taxes",
        ].contains(word)
      case .investing:
        return [
          "stock", "stocks", "share", "shares", "invest", "investment", "portfolio", "market",
          "ticker", "candle", "dividend", "yield", "etf", "fund", "bond", "treasury", "crypto",
          "bitcoin", "ethereum", "exchange", "fx", "dollar", "euro", "real", "pound", "yen", "gold",
          "commodity",
        ].contains(word)
      case .technology:
        return [
          "tech", "server", "cloud", "database", "data", "storage", "backup", "network", "wifi",
          "signal", "api", "code", "terminal", "bug", "robot", "ai", "agent", "automation",
          "workflow", "device", "phone", "laptop", "desktop", "monitor", "keyboard", "mouse", "chip",
          "gpu", "security", "privacy", "password", "key", "encryption", "firewall", "battery",
          "power", "update", "download", "upload", "link", "email", "message", "chat", "notify",
          "reminder", "calendar", "clock", "search", "settings", "profile",
        ].contains(word)
      case .shopping:
        return [
          "shop", "store", "cart", "basket", "order", "delivery", "tracking", "package", "gift",
          "tag", "offer", "cashback", "discount", "coupon", "loyalty", "points", "brand",
          "subscription", "recurring", "renewal", "cancel", "unsubscribe", "zombie",
        ].contains(word)
      case .travel:
        return [
          "flight", "plane", "airport", "trip", "travel", "hotel", "stay", "car", "taxi", "bus",
          "train", "bike", "walk", "map", "location", "address", "globe", "visa", "passport",
        ].contains(word)
      case .life:
        return [
          "food", "restaurant", "lunch", "dinner", "coffee", "drink", "groceries", "market-food",
          "bakery", "health", "fitness", "gym", "doctor", "medicine", "sleep", "home", "rent",
          "utilities", "water", "wifi-bill", "cleaning", "pet", "kids", "education", "book", "music",
          "film", "game", "sport", "nature", "weather", "sun", "rain", "snow",
        ].contains(word)
      case .status:
        return [
          "done", "success", "pending", "waiting", "failed", "error", "warning", "info", "help",
          "blocked", "frozen", "active", "paused", "expired", "verified", "protected", "new",
          "trending", "falling", "increase", "decrease", "fast", "slow", "urgent", "star",
          "favourite", "flag", "person", "people", "family", "company", "government", "law",
          "contract", "signature", "stamp",
        ].contains(word)
      }
    }
  }

  static let fallback = "circle.dashed"

  /// Does the running system actually carry this mark?
  static func exists(_ symbol: String) -> Bool {
    UIImage(systemName: symbol) != nil
  }

  /// How much of the vocabulary resolves on this device — used by the tests, and
  /// worth showing honestly rather than claiming a number.
  static func resolvableCount() -> (resolved: Int, total: Int) {
    let resolved = vocabulary.values.filter { exists($0) }.count
    return (resolved, vocabulary.count)
  }
}
