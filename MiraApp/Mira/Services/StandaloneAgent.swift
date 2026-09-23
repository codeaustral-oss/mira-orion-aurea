import Foundation
import Security

// MARK: - The assistant, with no server behind it
//
// The app can run the assistant by itself. Two halves:
//
//  1. **Money questions are answered here**, from the app's own ledger and plan.
//     A balance, a budget or a card question never needs a network at all, and
//     the numbers are the same ones the screens show, because they are the same
//     values.
//
//  2. **Everything else** goes to the model directly, over the same OpenCode Go
//     API the macOS proxy uses. The credential is pasted once on the device (or
//     injected at install time from the gitignored `.env`) and kept in the
//     keychain; several accounts may be present and are tried in turn.
//
// What deliberately does not run here: the research tasks. Those need the
// search-and-browse runtime that lives on a Mac. Without it the app says so
// rather than pretending to look something up.

struct StandaloneSnapshot: Sendable {
  var appName: String
  var available: String
  var holdings: [String]
  /// The last few movements, newest first: "Spent BRL 150.00 · Studio Floripa".
  var recent: [String] = []
  /// People saved on the device.
  var contacts: [String] = []
  /// Bills the person listed: "Internet · day 5".
  var bills: [String] = []
  var weekLeft: String
  var weeklyBudget: String
  var reserve: String
  var unallocated: String
  var planApproved: Bool
  var cardFrozen: Bool

  /// The state block the model gets. Deliberately the same substance the proxy
  /// would send: facts, no identifiers.
  var digest: String {
    var lines = ["BALANCES", "Available USD \(available)"]
    lines += holdings.map { "Holding \($0)" }
    lines += [
      "",
      "PLAN",
      "Weekly budget \(weeklyBudget). Left this week \(weekLeft).",
      "Reserve \(reserve). Unallocated \(unallocated).",
      "Plan approved: \(planApproved ? "yes" : "no")",
      "",
      "CARD",
      "Card is \(cardFrozen ? "frozen" : "active").",
    ]
    return lines.joined(separator: "\n")
  }
}

struct StandaloneAnswer: Sendable {
  var say: String
  var action: AgentAction?
  var model: String
  var latencyMs: Int
  /// The price behind the sentence, when the answer was a quote. A "yes"
  /// afterwards acts on this exact quote — never on a number the model retold.
  var quote: SwapQuote? = nil
}

// MARK: - Credentials

enum ModelKeyStore {
  private static let service = "com.codeaustral.mira.model"
  private static let account = "opencode-go"

  /// Keys in the order they should be tried: what the user pasted, then anything
  /// injected at install time. Never logged, never shown back.
  static func keys() -> [String] {
    var found: [String] = []
    if let stored = readKeychain(), !stored.isEmpty {
      found.append(contentsOf: stored.split(separator: "\n").map(String.init))
    }
    for name in ["MIRAOpenCodeKey", "MIRAOpenCodeKey2", "MIRAOpenCodeKey3"] {
      if let value = Bundle.main.object(forInfoDictionaryKey: name) as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { found.append(trimmed) }
      }
    }
    var seen = Set<String>()
    return found.filter { seen.insert($0).inserted }
  }

  static var hasKey: Bool { !keys().isEmpty }

  static func store(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = Data(trimmed.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard !trimmed.isEmpty else { return }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(add as CFDictionary, nil)
  }

  private static func readKeychain() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }
}

// MARK: - The model

enum DirectModel {
  static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!
  /// Tried in order: the assistant model first, the task model as a fallback.
  static let models = ["muse-spark-1.3-contributor", "deepseek-v4.1-flash"]

  /// Prose only. The reply cannot move money or choose an amount: anything with
  /// a consequence is a typed action the app builds and the user approves.
  static func ask(
    _ message: String,
    snapshot: StandaloneSnapshot,
    history: [(String, String)],
    timeout: TimeInterval = 60
  ) async -> StandaloneAnswer? {
    let keys = ModelKeyStore.keys()
    guard !keys.isEmpty else { return nil }
    let started = Date()

    let instructions = """
      You are Mira, the assistant inside \(snapshot.appName), a personal money app. \
      Answer in at most three short sentences. Use only the figures in the state below; \
      never invent a balance, a rate, a price or a date. You cannot move money, change a \
      limit or approve anything: the user does that. If a question needs live research, \
      say plainly that it needs the research runtime, which runs on a Mac.
      """

    var messages: [[String: String]] = [
      ["role": "system", "content": instructions],
      ["role": "system", "content": snapshot.digest],
    ]
    messages += history.suffix(6).map { ["role": $0.0, "content": String($0.1.prefix(600))] }
    messages.append(["role": "user", "content": message])

    for key in keys {
      for model in models {
        if let text = await call(model: model, messages: messages, key: key, timeout: timeout) {
          return StandaloneAnswer(
            say: text, action: nil, model: model,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000))
        }
      }
    }
    return nil
  }

  private static func call(
    model: String, messages: [[String: String]], key: String, timeout: TimeInterval
  ) async -> String? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("mira-app-direct", forHTTPHeaderField: "x-opencode-session")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["model": model, "messages": messages])

    do {
      // The model endpoint is not the proxy: this request must never carry the
      // proxy key, so it stays on the shared session.
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      // 429 and 5xx are worth the next account; anything else is an answer.
      guard http.statusCode != 429, !(500..<600).contains(http.statusCode) else { return nil }
      guard (200..<300).contains(http.statusCode) else { return nil }
      guard
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = root["choices"] as? [[String: Any]],
        let message = choices.first?["message"] as? [String: Any],
        let text = message["content"] as? String
      else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch {
      return nil
    }
  }
}

// MARK: - What the app can answer itself

enum StandaloneAgent {
  /// The one refusal line for investment, tax and legal advice. The proxy
  /// carries the same wording; neither is a model's sentence.
  static let adviceRefusal =
    "That is investment advice and I do not give it — nobody should, without knowing your whole position. "
    + "I can show you what you hold, what a fee costs you, and the public facts about anything you name."

  /// The one refusal line for a rate the app did not quote. The proxy's
  /// `rate-guard.mjs` carries the same wording.
  static let rateBookingRefusal =
    "I can only book a rate I quoted — I won't apply one that wasn't mine."

  /// Does the message state a rate of its own and ask to put it to work?
  ///
  /// Deliberately narrow: a rate-like pair (a written pair, a figure after
  /// "at", a figure put to "use", a per-unit rate) together with a booking verb
  /// (book / use / apply / fix / lock / set / adopt / commit). Legitimate
  /// conversions — "convert 100 usd to brl", "what is the rate" — never carry
  /// both, and an ordinary booking ("book a table at 12.30") carries no
  /// currency or rate word, so neither is refused.
  ///
  /// The proxy adds a typed read on top of this shape; this is the floor that
  /// still refuses when no read is available at all.
  static func asksToBookAForeignRate(_ message: String) -> Bool {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    let currency = #"(?:usd|brl|eur|gbp|usdc|usdt|dollars?|reais?|euros?|pounds?|r\$|€|£|\$)"#
    let number = #"\d[\d.,]*"#
    let shapes = [
      "\(number)\\s*\(currency)?\\s*(?:=|equals?|->|to|per|→)\\s*\(number)\\s*\(currency)",
      "\\bat\\s+\(number)(?:\\s*\(currency)\\b|[.,]\\d)",
      "\\buse\\s+(?:the\\s+)?(?:rate\\s+)?\(number)(?:\\s*\(currency)\\b)?",
      "\(number)\\s*\(currency)?\\s+per\\s+(?:dollar|real|euro|pound|usd|brl|eur|gbp|usdc|usdt)\\b",
      "\\b(?:usd|brl|eur|gbp|usdc|usdt)\\s*[/-]\\s*(?:usd|brl|eur|gbp|usdc|usdt)\\b[^.!?\\n]{0,16}\\b\(number)\\b",
      "\\b(?:rate|fx|exchange rate)\\s+of\\s+\(number)\\b",
    ]
    let hasShape = shapes.contains {
      text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
    guard hasShape else { return false }
    // The message must also say what currency or rate the figure belongs to.
    let context = "\(currency)|\\b(?:rate|rates|fx|conversion)\\b"
    guard text.range(of: context, options: [.regularExpression, .caseInsensitive]) != nil else {
      return false
    }
    let verbs = #"\b(book|apply|apply it|use|fix|lock|lock in|adopt|set|peg|commit|at\s+that\s+rate|use\s+that\s+rate|that\s+rate|the\s+rate\s+of)\b"#
    return text.range(of: verbs, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// The honest answer for a corridor this build does not price, or nil when
  /// the message is not about one. Never a transfer prompt, never a task.
  static func corridorAnswer(for message: String) -> String? {
    guard let code = CorridorSupport.corridorQuestion(in: message) else { return nil }
    return CorridorSupport.answer(for: code)
  }

  /// Someone said hello, and nothing else.
  ///
  /// A greeting is the most common first message and the one place a working
  /// row is least forgivable: there is nothing to research in "hi". It is
  /// answered here, in the frame it was typed — no router, no model, no wait.
  /// Anything longer, or with a request inside it ("hi, find me shoes"), is not
  /// a greeting and takes the normal path.
  static func greeting(for message: String) -> StandaloneAnswer? {
    let folded =
      message
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
      .replacingOccurrences(of: "[^a-zA-Z ]+", with: " ", options: .regularExpression)
      .lowercased()
    var words = folded.split(separator: " ").map(String.init)
    guard !words.isEmpty, words.count <= 3 else { return nil }
    // "hey mira" is still a greeting to Mira.
    if words.last == "mira" { words.removeLast() }
    guard !words.isEmpty else { return nil }
    let phrase = words.joined(separator: " ")

    let english: Set<String> = [
      "hi", "hey", "hello", "yo", "hi there", "hey there", "hello there",
      "good morning", "good afternoon", "good evening",
    ]
    let portuguese: Set<String> = [
      "oi", "ola", "bom dia", "boa tarde", "boa noite", "oi tudo bem", "oi tudo bom", "e ai",
    ]
    let spanish: Set<String> = ["hola", "buenos dias", "buenas tardes", "buenas noches", "que tal"]

    // A repeated hello ("hi hi", "hey hey mira") is still a hello. Every word
    // must be a greeting word: "hi find me shoes" has a request inside it and
    // stays a request.
    let englishWords: Set<String> = ["hi", "hey", "hye", "hello", "yo"]
    let portugueseWords: Set<String> = ["oi", "ola"]
    let spanishWords: Set<String> = ["hola"]
    if words.allSatisfy({ englishWords.contains($0) }) {
      return StandaloneAnswer(say: "Hey. What can I help you with?", action: nil, model: "on-device", latencyMs: 0)
    }
    if words.allSatisfy({ portugueseWords.contains($0) }) {
      return StandaloneAnswer(say: "Oi. Como posso ajudar?", action: nil, model: "on-device", latencyMs: 0)
    }
    if words.allSatisfy({ spanishWords.contains($0) }) {
      return StandaloneAnswer(say: "Hola. ¿Cómo puedo ayudarte?", action: nil, model: "on-device", latencyMs: 0)
    }

    let say: String
    if portuguese.contains(phrase) {
      say = "Oi. Como posso ajudar?"
    } else if spanish.contains(phrase) {
      say = "Hola. ¿Cómo puedo ayudarte?"
    } else if english.contains(phrase) {
      say = "Hey. What can I help you with?"
    } else {
      return nil
    }
    return StandaloneAnswer(say: say, action: nil, model: "on-device", latencyMs: 0)
  }

  /// The questions that never need a model, because the answer is already in the
  /// app and the number has to be the number on the screen.
  static func localAnswer(
    for message: String, snapshot: StandaloneSnapshot
  ) -> StandaloneAnswer? {
    let text = message.lowercased()

    func answer(_ say: String, _ kind: AgentAction.Kind, topic: String? = nil) -> StandaloneAnswer {
      var action = AgentAction(kind: kind)
      action.topic = topic
      return StandaloneAnswer(say: say, action: action, model: "on-device", latencyMs: 0)
    }

    // ── The refusals and the document ─────────────────────────────────────
    // These come before every other local answer, so a rate we did not quote
    // can never be applied by a later branch, and a question about the build
    // can never be answered as a balance or a transfer.
    if asksToBookAForeignRate(message) {
      return answer(rateBookingRefusal, .reply)
    }
    if CapabilityDocument.asksAboutThisBuild(message) {
      return answer(CapabilityDocument.answer, .reply)
    }
    if let corridor = corridorAnswer(for: message) {
      return answer(corridor, .reply)
    }

    // Balance
    if matches(text, ["balance", "how much do i have", "how much is in", "where is my money",
                      "my money", "holdings", "available"]) {
      let others = snapshot.holdings.isEmpty ? "" : " Plus \(snapshot.holdings.joined(separator: ", "))."
      return answer("You have USD \(snapshot.available) available.\(others)", .showBalance)
    }

    // This week's budget — the question the brief is built around.
    if matches(text, ["this week", "weekly", "left to spend", "can i spend", "budget", "left this week",
                      "spend this week"]) {
      let tail = snapshot.planApproved
        ? ""
        : " The plan is not approved yet, so nothing is committed."
      return answer(
        "You have \(snapshot.weekLeft) left this week, out of \(snapshot.weeklyBudget).\(tail)",
        .showBudget)
    }

    // Card state
    if matches(text, ["freeze", "unfreeze", "frozen", "my card", "card controls"]) {
      let freezing = matches(text, ["freeze", "frozen"]) && !text.contains("unfreeze")
      return answer(
        freezing
          ? (snapshot.cardFrozen ? "The card is already frozen." : "Your card will be frozen.")
          : (snapshot.cardFrozen ? "Your card is unfrozen again." : "Your card is active."),
        .openCardControls)
    }

    // Receiving
    if matches(text, ["receive", "receiving", "get paid", "my details", "account details"]) {
      return answer("Here are your receiving details.", .openReceive)
    }

    // A conversion, priced here from the app's own rate table.
    if let fx = fxAnswer(for: message, snapshot: snapshot) { return fx }

    // Reserve
    if matches(text, ["reserve"]) {
      return answer("Your reserve is \(snapshot.reserve) and it stays where it is unless you move it.", .showBudget)
    }

    return nil
  }

  // MARK: FX — priced on the device

  /// The records Jev pointed at, answered here and now from the app's own
  /// database. This is the fast path the router exists to protect: no network,
  /// no model, no wait — the answer is already on the device.
  static func recordAnswer(
    needs: String, message: String, snapshot: StandaloneSnapshot
  ) -> StandaloneAnswer? {
    let text = message.lowercased()
    switch needs {
    case "activity":
      guard !snapshot.recent.isEmpty else {
        return StandaloneAnswer(
          say: "Nothing has moved yet in this session.", action: nil,
          model: "on-device", latencyMs: 0)
      }
      return StandaloneAnswer(
        say: "The last few: " + snapshot.recent.prefix(3).joined(separator: " · ") + ".",
        action: nil, model: "on-device", latencyMs: 0)

    case "contacts":
      guard !snapshot.contacts.isEmpty else {
        return StandaloneAnswer(
          say: "You have no one saved yet. Add someone in Contacts and I can address a payment to them.",
          action: nil, model: "on-device", latencyMs: 0)
      }
      return StandaloneAnswer(
        say: "Saved: " + snapshot.contacts.prefix(5).joined(separator: ", ") + ".",
        action: nil, model: "on-device", latencyMs: 0)

    case "bills":
      guard !snapshot.bills.isEmpty else {
        return StandaloneAnswer(
          say: "No bills listed yet. Add them and I will count each one against your plan.",
          action: nil, model: "on-device", latencyMs: 0)
      }
      return StandaloneAnswer(
        say: "Your bills: " + snapshot.bills.prefix(5).joined(separator: " · ") + ".",
        action: nil, model: "on-device", latencyMs: 0)

    default:
      break
    }
    // The records the original local answers already cover.
    return localAnswer(for: text, snapshot: snapshot)
  }

  /// A conversion, priced by the app itself. The rate table ships in the app, so
  /// "change 100 USD to BRL" is a calculation, not a research request: it can be
  /// answered in the same breath, with the fee, and the same rate the Move money
  /// screen will show.
  static func fxAnswer(for message: String, snapshot: StandaloneSnapshot) -> StandaloneAnswer? {
    let text = message.lowercased()
    let words = assetWords(in: text)
    guard !words.isEmpty else { return nil }
    // A currency named in a message about something else is not a conversion:
    // "buy a wallet for my euros" is a wallet. A sentence that names a priced
    // corridor with an amount — "a client pays EUR 500 … converting to BRL" —
    // is a conversion even though it has a subject, and it prices here.
    guard isMoneyOnly(message) || namesAPricedCorridor(message) else { return nil }

    let wantsConversion = matches(text, ["convert", "exchange", "change", "swap", "rate",
                                         "how much is", "how many", "worth", "to reais", "to dollars",
                                         "em reais", "em dólares",
                                         // In a money app, "buy euros" is a conversion, not a
                                         // shopping list — and it must be priced, not researched.
                                         "buy", "sell", "purchase", "need", "want", "get"])
    guard wantsConversion else { return nil }

    // The direction the person means, not the order they typed it.
    var pair = conversionPair(in: message)
    if pair == nil, let only = words.first {
      pair = conversionIntent(from: only, text: text, snapshot: snapshot)
    }
    guard let pair, pair.from != pair.to else { return nil }
    let source = pair.from
    let destination = pair.to

    let rateLine: String
    if let rate = RateTable.current.cross(from: source, to: destination) {
      rateLine = "1 \(source.code) = \(DecimalFormatting.plain(rate, scale: 4)) \(destination.code)"
        + rateAgeSuffix()
    } else {
      return nil
    }

    guard let amount = amount(in: text, asset: source) else {
      return StandaloneAnswer(
        say: "\(rateLine). Tell me an amount and I will price it, fee included.",
        action: nil, model: "on-device", latencyMs: 0)
    }

    guard let quote = try? SimulatedSwapProvider(table: RateTable.current).quote(
      from: source, to: destination, amount: amount)
    else {
      return StandaloneAnswer(
        say: "\(rateLine). I could not price \(amount.display) just now.",
        action: nil, model: "on-device", latencyMs: 0)
    }

    return StandaloneAnswer(
      say: """
        \(rateLine). \(quote.fromAmount.display) becomes \(quote.toAmount.display); \
        the fee is \(quote.fee.display), so the all-in cost is \(quote.totalDebit.display). \
        Say the word and I'll make the swap — nothing moves until you do.
        """,
      action: nil, model: "on-device", latencyMs: 0, quote: quote)
  }

  /// Is the message about the money itself — a currency, a buying or selling
  /// verb, context ("for my trip") and nothing else of substance?
  static func isMoneyOnly(_ message: String) -> Bool {    let words = message
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
    guard !words.isEmpty else { return false }
    let ignorable: Set<String> = [
      "usd", "usdc", "usdt", "eur", "euro", "euros", "brl", "real", "reais", "gbp", "pound", "pounds",
      "dollar", "dollars", "buck", "bucks", "r",
      "buy", "sell", "purchase", "get", "need", "want", "like", "some", "for", "my", "a", "an", "the",
      "of", "to", "in", "into", "and", "or", "i", "me", "is", "are", "much", "many", "how", "worth",
      "exchange", "convert", "change", "swap", "rate", "rates", "please", "can", "could", "you",
      "trip", "travel", "holiday", "holidays", "vacation", "weekend", "flight", "flights", "abroad",
      "today", "tomorrow", "tonight", "now", "at", "on", "with", "from", "about", "around", "up",
    ]
    return words.allSatisfy { word in
      ignorable.contains(word) || Int(word) != nil || Double(word) != nil
    }
  }

  /// A sentence about moving money between two quoted currencies, with an
  /// amount in one of them: "a client in Lisbon pays EUR 500 — what does
  /// converting to BRL cost?". It carries a subject, so it fails `isMoneyOnly`,
  /// but the corridor itself is priced and the answer should be a quote, never
  /// a receiving card or a model paragraph. A message naming a currency this
  /// build cannot price belongs to the corridor answer instead, and is left
  /// alone here.
  static func namesAPricedCorridor(_ message: String) -> Bool {
    let text = message.lowercased()
    guard CorridorSupport.unquotedCurrency(in: message) == nil else { return false }
    let codes = Set(assetWords(in: text).map(\.code))
    guard codes.count >= 2, number(in: text) != nil else { return false }
    return matches(text, [
      "convert", "converting", "exchange", "change", "swap", "rate", "how much", "worth", "cost",
      "lands", "becomes", "in brl", "in usd", "in eur", "to reais", "to dollars", "to euros",
    ])
  }

  /// One named currency and a verb: which side of the conversion it is on.
  ///
  /// "buy euros" wants euros; "sell dollars" gives dollars away; anything else
  /// keeps the older reading (the named currency is the one being priced).
  private static func conversionIntent(
    from named: Asset, text: String, snapshot: StandaloneSnapshot?
  ) -> (from: Asset, to: Asset) {
    let buying = matches(text, ["buy", "purchase", "need", "want", "get", "into"])
    let selling = matches(text, ["sell"])
    if buying {
      return (sourceFor(destination: named, snapshot: snapshot), named)
    }
    if selling {
      return (named, sourceFor(destination: named, snapshot: snapshot))
    }
    return (named, named == .usd ? .brl : .usd)
  }

  /// The currency a conversion spends from: USD unless USD is the one being
  /// bought, in which case the largest other holding the snapshot shows.
  private static func sourceFor(destination: Asset, snapshot: StandaloneSnapshot?) -> Asset {
    if destination != .usd { return .usd }
    for holding in snapshot?.holdings ?? [] {
      let code = holding.split(separator: " ").first.map(String.init) ?? ""
      if let asset = Asset.all.first(where: { $0.code == code }), asset != destination {
        return asset
      }
    }
    return .eur
  }

  /// The currencies in a conversion, in the direction the person means.
  ///
  /// Order of mention is not direction: "I need EUR for change from my USD"
  /// names EUR first and means USD → EUR. "From my X" is the currency they
  /// hold; "need/want/get X" is the one they want.
  static func conversionPair(in text: String) -> (from: Asset, to: Asset)? {
    let lowered = text.lowercased()
    let held = assetWords(in: capture(lowered, after: ["from my", "from the", "using my", "with my", "from"]))
    let wanted = assetWords(in: capture(lowered, after: ["need", "want", "get", "into", "to buy", "buy"]))

    if let source = held.first, let destination = wanted.first, source != destination {
      return (source, destination)
    }
    let mentioned = assetWords(in: lowered)
    guard mentioned.count >= 2 else { return nil }
    // Two currencies and no directional words: "USD to EUR" reads left to right.
    return (mentioned[0], mentioned[1])
  }

  private static func capture(_ text: String, after leads: [String]) -> String {
    for lead in leads {
      if let range = text.range(of: lead + " ") {
        return String(text[range.upperBound...]).trimmingCharacters(in: .punctuationCharacters)
      }
    }
    return ""
  }

  /// Which currencies the message names, in the order they appear.
  private static func assetWords(in text: String) -> [Asset] {
    let table: [(Asset, [String])] = [
      (.usd, ["usd", "us dollar", "dollar", "dollars", "dólar", "dólares", "dolares"]),
      (.brl, ["brl", "real", "reais", "r$"]),
      (.eur, ["eur", "euro", "euros"]),
      (.gbp, ["gbp", "pound", "pounds", "sterling"]),
      (.usdc, ["usdc", "usd coin"]),
      (.usdt, ["usdt", "tether"]),
    ]
    var found: [(Int, Asset)] = []
    for (asset, needles) in table {
      for needle in needles {
        if let range = text.range(of: needle) {
          found.append((text.distance(from: text.startIndex, to: range.lowerBound), asset))
          break
        }
      }
    }
    return found.sorted { $0.0 < $1.0 }.map(\.1)
  }

  /// A bare amount in a follow-up: "100", "100 eur", "R$ 150".
  ///
  /// This is the answer to "tell me an amount", so it is read generously: the
  /// figure is taken, and a currency named beside it decides which side of the
  /// conversion it belongs to.
  static func amountRequest(_ message: String) -> (value: Decimal, asset: Asset?)? {
    let text = message.lowercased()
    let words = assetWords(in: text)
    guard let value = number(in: text) else { return nil }
    return (value, words.first)
  }

  /// The first figure in the message, read the way a person would write it.
  private static func amount(in text: String, asset: Asset) -> Money? {
    guard let decimal = number(in: text) else { return nil }
    return Money(majorUnits: decimal, currency: asset)
  }

  private static func number(in text: String) -> Decimal? {
    guard let regex = try? NSRegularExpression(pattern: "([0-9][0-9.,]*)") else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    for match in regex.matches(in: text, range: range) {
      guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
      let raw = String(text[valueRange])
      guard let decimal = InstructionParser.decimal(fromLocalised: raw), decimal > 0 else { continue }
      // A figure that reads as a year or a house number is not an amount.
      if decimal >= 1900 && decimal <= 2100 && !raw.contains(".") && !raw.contains(",") { continue }
      return decimal
    }
    return nil
  }

  /// Price a conversion the person has already asked for, now that they have
  /// said how much. "I need EUR from my USD" → "100 eur" is the amount in the
  /// currency they said they need, which is the *destination* side.
  static func pricePendingConversion(
    from source: Asset, to destination: Asset, value: Decimal, statedIn stated: Asset?
  ) -> StandaloneAnswer? {
    let rate = RateTable.current.cross(from: source, to: destination)
    guard let rate, rate > 0 else { return nil }
    let rateLine = "1 \(source.code) = \(DecimalFormatting.plain(rate, scale: 4)) \(destination.code)"
      + rateAgeSuffix()

    // If they named the currency they need, treat the figure as that side of
    // the conversion; otherwise it is the amount they are spending.
    let targetIsDestination = stated == destination
    let toAmount = Money(majorUnits: value, currency: targetIsDestination ? destination : source)
    let fromAmount = targetIsDestination
      ? Money(majorUnits: value / rate, currency: source)
      : Money(majorUnits: value, currency: source)
    let converted = targetIsDestination
      ? toAmount
      : Money(majorUnits: fromAmount.majorUnits * rate, currency: destination)

    guard let quote = try? SimulatedSwapProvider(table: RateTable.current).quote(
      from: source, to: destination, amount: fromAmount)
    else { return nil }

    return StandaloneAnswer(
      say: """
        \(rateLine). \(quote.fromAmount.display) becomes \(quote.toAmount.display); the fee is \
        \(quote.fee.display), so the all-in cost is \(quote.totalDebit.display). \
        Say the word and I'll make the swap — nothing moves until you do.
        """,
      action: nil, model: "on-device", latencyMs: 0, quote: quote)
  }

  /// Buying a security is an order to a broker, not a purchase from a shop.
  /// "buy 10 shares of AAPL" must not open a checkout for "10 shares of AAPL".
  static func looksLikeSecurityOrder(_ message: String) -> Bool {
    let text = message.lowercased()
    return text.range(
      of: "\\b(invest|investment|investing|stocks?|shares?|equit(?:y|ies)|etfs?|index fund|treasur(?:y|ies)|bonds?|portfolio|dividend|ticker|nyse|nasdaq|aapl|tsla|nvda|msft|amzn|googl|goog|meta|spy|qqq|vti|bnd)\\b",
      options: .regularExpression) != nil
  }

  /// Sending money — to a friend, a family member, a shop. It is a transfer,
  /// and a capability that returns links cannot send it.
  static func looksLikeMoneyMovement(_ message: String) -> Bool {
    let text = message.lowercased()
    guard
      text.range(
        of: "\\b(send|pay|transfer|pix|zelle|venmo|cash ?app|sepa|swift|wire|remit|top ?up|withdraw|deposit)\\b",
        options: .regularExpression) != nil
    else { return false }
    // "how do I send money" is a question about it, not a request to move it.
    if text.range(
      of: "^(what|why|how|who|when|where|is|are|does|do|can|could|should)\\b", options: [.regularExpression]) != nil,
      text.range(of: "\\b(please|now|today)\\b", options: .regularExpression) == nil
    {
      return false
    }
    return true
  }

  /// The rail a person named, so the question can use their word for it.
  static func transferRail(_ message: String) -> String? {
    let text = message.lowercased()
    for rail in ["pix", "zelle", "venmo", "cash app", "sepa", "swift", "wire"] where text.contains(rail) {
      return rail == "pix" ? "Pix" : rail.capitalized
    }
    return nil
  }

  /// A message that is *only* an amount — "100", "100 eur", "R$ 250". A number
  /// inside a sentence ("and with 2 travellers") is part of that sentence, not
  /// the amount a quote was waiting for.
  static func isAmountOnly(_ message: String) -> Bool {
    // Digits survive here on purpose: this check is about the number.
    let text =
      message
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
      .replacingOccurrences(of: "[^a-zA-Z0-9$€,. ]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
    let words = text.split(separator: " ").map(String.init)
    guard !words.isEmpty, words.count <= 3 else { return false }
    let currencyWords: Set<String> = [
      "usd", "eur", "brl", "usdc", "usdt", "dollars", "dollar", "euros", "euro", "reais", "real",
      "r", "us", "bucks", "$", "€",
    ]
    return words.allSatisfy { word in
      if word.rangeOfCharacter(from: .decimalDigits) != nil { return true }
      let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?€$£"))
      return currencyWords.contains(clean)
    }
  }

  /// Does this message ask about money changing currencies? The session uses
  /// it to refresh the live table before pricing, so a quote is as fresh as the
  /// sources allow.
  static func mentionsConversion(_ message: String) -> Bool {
    let text = message.lowercased()
    guard !assetWords(in: text).isEmpty else { return false }
    return matches(text, ["convert", "exchange", "change", "swap", "rate", "how much is",
                          "how many", "worth", "to reais", "to dollars", "em reais", "em dólares",
                          "buy", "sell", "purchase", "need", "want", "get"])
  }

  /// " · live 12:13" when the rate was fetched, nothing when it is the
  /// reference table the build ships with.
  static func rateAgeSuffix() -> String {
    guard let label = RateTable.current.ageLabel else { return "" }
    return " · \(label)"
  }

  /// A yes. Short, in the languages this prototype is used in, and never a
  /// whole sentence — "yes, but change the amount" is not a plain yes.
  static func isAffirmative(_ message: String) -> Bool {
    let text = normalised(message)
    let words = text.split(separator: " ").map(String.init)
    guard words.count <= 4 else { return false }
    let yes: Set<String> = ["yes", "y", "yeah", "yep", "sure", "ok", "okay", "confirm", "confirmed",
                            "do it", "go ahead", "go", "place it", "place the order", "send it",
                            "swap it", "do the swap", "make the swap", "execute",
                            "sim", "claro", "pode", "si", "dale", "hazlo"]
    if yes.contains(text) { return true }
    return words.count <= 3 && yes.contains(words.joined(separator: " "))
  }

  /// A no, the same way.
  static func isNegative(_ message: String) -> Bool {
    let text = normalised(message)
    let no: Set<String> = ["no", "n", "nope", "cancel", "stop", "not now", "never mind", "nevermind",
                           "nao", "não", "no thanks", "no thank you", "deixa", "dejalo"]
    return no.contains(text)
  }

  private static func normalised(_ message: String) -> String {
    message
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
      .replacingOccurrences(of: "[^a-zA-Z ]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
  }

  /// The pair of currencies a rate-only answer is about, so the next message —
  /// which will be an amount — can be priced without asking again.
  static func pendingPair(
    for message: String, snapshot: StandaloneSnapshot? = nil
  ) -> (from: Asset, to: Asset)? {
    guard isMoneyOnly(message) else { return nil }
    let text = message.lowercased()
    guard matches(text, ["convert", "exchange", "change", "swap", "rate", "how much is", "how many",
                          "worth", "buy", "sell", "purchase", "need", "want", "get"]) else { return nil }
    if let pair = conversionPair(in: message) { return pair }
    if let only = assetWords(in: text).first {
      return conversionIntent(from: only, text: text, snapshot: snapshot)
    }
    if let only = assetWords(in: text).first { return (only, only == .usd ? .brl : .usd) }
    return nil
  }

  private static func matches(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }
}
