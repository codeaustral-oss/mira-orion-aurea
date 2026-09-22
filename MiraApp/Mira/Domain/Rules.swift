import Foundation

// MARK: - The rule contract
//
// An automation written the way the essay writes it:
//
//   When <trigger> → Do <action> → Protect <things> → Pause when <condition>
//
// with three delegation levels — `prepare`, `ask`, `autopilot` — and an
// editable, persisted contract. The person approves the *structured rule*, not
// the sentence that proposed it; the app's own reader turns the sentence into
// the structure, and code validates every field.
//
// Triggers are the events this app can actually honour with records it holds:
// a settled relay payment arriving from a named payer, a subscription charge
// day, a price-claim window, a watch result. Actions are existing verbs or the
// app's own engine actions — never free-form. Autopilot may run a `prepare`
// verb, or a `commit` whose consent has passed the same policy the rest of the
// app uses, and only inside the narrow mandate: cap, expiry, run count.
//
// This mirrors `server/lib/rule-contract.mjs`, so a phone with no proxy behaves
// exactly as the server does rather than more freely.

struct RuleContract: Identifiable, Codable, Hashable, Sendable {
  enum TriggerKind: String, Codable, Hashable, Sendable, CaseIterable {
    case paymentReceived = "payment_received"
    case subscriptionCharge = "subscription_charge"
    case priceClaimWindow = "price_claim_window"
    case watchResult = "watch_result"

    var label: String {
      switch self {
      case .paymentReceived: return "A settled payment arrives from a named payer"
      case .subscriptionCharge: return "A subscription reaches its charge day"
      case .priceClaimWindow: return "A price-claim window is open"
      case .watchResult: return "A standing watch returns a new result"
      }
    }

    var subjectLabel: String {
      switch self {
      case .paymentReceived: return "payer"
      case .subscriptionCharge: return "subscription name"
      case .priceClaimWindow: return "item"
      case .watchResult: return "watched subject"
      }
    }

    var shortLabel: String {
      switch self {
      case .paymentReceived: return "Payment received"
      case .subscriptionCharge: return "Charge day"
      case .priceClaimWindow: return "Claim window"
      case .watchResult: return "Watch result"
      }
    }
  }

  enum Delegation: String, Codable, Hashable, Sendable, CaseIterable {
    case prepare
    case ask
    case autopilot

    var label: String {
      switch self {
      case .prepare: return "Prepare it and show me"
      case .ask: return "Ask me first"
      case .autopilot: return "Run it inside the mandate"
      }
    }
  }

  struct Trigger: Codable, Hashable, Sendable {
    var kind: TriggerKind
    var subject: String
  }

  struct Action: Codable, Hashable, Sendable {
    struct Params: Codable, Hashable, Sendable {
      var sharePercent: Double?
      var amountMinor: Int64?
    }

    var verb: String
    var params: Params?

    var sharePercent: Double? { params?.sharePercent }
    var amountMinor: Int64? { params?.amountMinor }
  }

  struct Mandate: Codable, Hashable, Sendable {
    var amountCapMinor: Int64?
    var currencyCode: String?
    var expiresAt: Date?
    var maxRuns: Int?
    var runsUsed: Int = 0
    /// "low" or "high"; a high-risk mandate still stops for a person.
    var risk: String?
  }

  var id: UUID = UUID()
  /// The words that proposed it, kept for the audit trail.
  var sentence: String
  var trigger: Trigger
  var action: Action
  var protect: [String] = []
  var pauseWhen: [String] = []
  var delegation: Delegation = .prepare
  var mandate = Mandate()
  var isApproved: Bool = false
  var approvedAt: Date?
  var proposedBy: String = "rules"
  /// Informational only. No decision reads it.
  var confidence: Double?
  /// Set by "pause the rule"; it holds until "resume the rule".
  var paused: Bool = false
  var createdAt: Date = Date()
}

enum RuleVerbClass: String, Hashable, Sendable {
  case observe
  case prepare
  case commit
}

enum RuleDecisionKind: String, Hashable, Sendable {
  case run
  case ask
  case prepare
  case refuse
}

struct RuleDecision: Hashable, Sendable {
  var kind: RuleDecisionKind
  var reason: String
  var withinMandate: Bool
}

/// Facts the app holds when a trigger fires. They evaluate the rule's pause
/// conditions; nothing here is a guess.
struct RuleFacts: Hashable, Sendable {
  var planShortfall: Bool = false
  var incomeNotArrived: Bool = false
  var goalProtected: Bool = false
  var amountAboveCap: Bool = false
  var paused: Bool = false
}

enum RulesEngine {
  static let protections = ["reserve", "plan", "goal", "standing"]
  static let pauseConditions = [
    "amount_above_cap", "plan_shortfall", "income_not_arrived", "goal_protected", "paused",
  ]

  /// The verbs a rule may carry: the app's engine actions and the existing
  /// bounded verbs that make sense to repeat. Never a free-form string.
  static let verbClasses: [String: RuleVerbClass] = [
    "engine.reserve.share": .prepare,
    "engine.income.smooth": .prepare,
    "engine.subscriptions.review": .observe,
    "engine.price_claim.prepare": .prepare,
    "watch.create": .prepare,
    "task.create": .prepare,
    "transfer.prepare": .prepare,
    "budget.prepare": .prepare,
    "subscription.cancel": .commit,
  ]

  static let actionLabels: [String: String] = [
    "engine.reserve.share": "Put a share of the money into the reserve",
    "engine.income.smooth": "Carve the money into tax, buffer and spendable",
    "engine.subscriptions.review": "Review the recurring charges for waste",
    "engine.price_claim.prepare": "Prepare the price-match claim",
    "watch.create": "Start or keep a standing watch",
    "task.create": "Start a research or preparation task",
    "transfer.prepare": "Prepare a transfer to the named person",
    "budget.prepare": "Prepare an allocation or budget change",
    "subscription.cancel": "Cancel the named recurring charge",
  ]

  /// Actions whose amount a cap must be able to check.
  static let amountBearing: Set<String> = [
    "engine.reserve.share", "engine.income.smooth", "transfer.prepare", "budget.prepare",
  ]

  static func verbClass(_ verb: String) -> RuleVerbClass? { verbClasses[verb] }

  static func label(for verb: String) -> String { actionLabels[verb] ?? verb }

  // MARK: Validation

  /// Every unknown or missing value is named. Deterministic and total.
  static func validate(_ contract: RuleContract) -> [String] {
    var errors: [String] = []
    if contract.trigger.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errors.append("the rule needs its \(contract.trigger.kind.subjectLabel) named")
    }

    guard verbClass(contract.action.verb) != nil else {
      errors.append("the action is not an existing verb or engine action")
      return errors
    }

    switch contract.action.verb {
    case "engine.reserve.share":
      let share = contract.action.sharePercent
      let amount = contract.action.amountMinor
      if share != nil && amount != nil {
        errors.append("a reserve share is either a percentage or an amount, not both")
      }
      if let share, !(share > 0 && share <= 100) {
        errors.append("the share must be between 0 and 100")
      }
      if let amount, amount <= 0 {
        errors.append("the amount must be positive")
      }
    default:
      if contract.action.params != nil {
        errors.append("'\(contract.action.verb)' takes no parameters")
      }
    }

    for protection in contract.protect {
      let known = protections.contains(protection) || protection.hasPrefix("goal:")
      if !known { errors.append("unknown protection '\(protection)'") }
    }
    for condition in contract.pauseWhen where !pauseConditions.contains(condition) {
      errors.append("unknown pause condition '\(condition)'")
    }

    if let cap = contract.mandate.amountCapMinor, cap <= 0 {
      errors.append("the amount cap must be positive")
    }
    if let runs = contract.mandate.maxRuns, runs <= 0 {
      errors.append("the run count must be positive")
    }
    if contract.mandate.runsUsed < 0 {
      errors.append("runs used cannot be negative")
    }
    if let risk = contract.mandate.risk, risk != "low" && risk != "high" {
      errors.append("risk is low or high")
    }

    if contract.delegation == .autopilot {
      if contract.mandate.expiresAt == nil && contract.mandate.maxRuns == nil {
        errors.append("an autopilot rule needs an expiry or a run count")
      }
      if amountBearing.contains(contract.action.verb), contract.mandate.amountCapMinor == nil {
        errors.append("'\(contract.action.verb)' carries an amount, so autopilot needs an amount cap")
      }
    }
    return errors
  }

  // MARK: Pause conditions

  static func pausedBy(_ contract: RuleContract, facts: RuleFacts) -> String? {
    let active = Set(contract.pauseWhen)
    if facts.paused || contract.paused || active.contains("paused") { return "paused" }
    if facts.planShortfall && active.contains("plan_shortfall") { return "plan_shortfall" }
    if facts.incomeNotArrived && active.contains("income_not_arrived") { return "income_not_arrived" }
    if facts.goalProtected && active.contains("goal_protected") { return "goal_protected" }
    if facts.amountAboveCap && active.contains("amount_above_cap") { return "amount_above_cap" }
    return nil
  }

  // MARK: The decision

  /// The person's structured approval, read as the typed consent the app's one
  /// policy already understands. An unapproved contract has no consent, and a
  /// high-risk mandate still produces a read the policy stops.
  static func approvalConsent(_ contract: RuleContract) -> ConsentRead? {
    guard contract.isApproved, contract.approvedAt != nil else { return nil }
    return ConsentRead(
      ok: true,
      authorises: 1,
      suppliesDetail: 1,
      missing: "none",
      risk: contract.mandate.risk == "high" ? "high" : "low")
  }

  /// May this rule run right now? Mirrors `automationDecision` in the server
  /// module. No confidence is read anywhere in here.
  static func decision(
    for contract: RuleContract,
    amount: Money? = nil,
    now: Date = Date(),
    facts: RuleFacts = RuleFacts(),
    consent: ConsentRead? = nil
  ) -> RuleDecision {
    let errors = validate(contract)
    guard errors.isEmpty else {
      return RuleDecision(
        kind: .refuse, reason: "the contract is invalid", withinMandate: false)
    }

    if let paused = pausedBy(contract, facts: facts) {
      return RuleDecision(
        kind: .prepare, reason: "held: \(paused)", withinMandate: true)
    }

    if let expiry = contract.mandate.expiresAt, now > expiry {
      return RuleDecision(kind: .refuse, reason: "the rule expired", withinMandate: false)
    }
    if let maxRuns = contract.mandate.maxRuns, contract.mandate.runsUsed >= maxRuns {
      return RuleDecision(
        kind: .refuse, reason: "the rule used its run count", withinMandate: false)
    }

    let isAmountBearing = amountBearing.contains(contract.action.verb)
    if let cap = contract.mandate.amountCapMinor {
      if amount == nil && isAmountBearing {
        return RuleDecision(
          kind: .ask, reason: "the amount is not known, so the cap cannot be checked",
          withinMandate: false)
      }
      if let amount {
        if let code = contract.mandate.currencyCode, code != amount.currency.code {
          return RuleDecision(
            kind: .ask, reason: "the cap is in \(code), so it cannot be checked here",
            withinMandate: false)
        }
        if amount.minorUnits > cap {
          return RuleDecision(kind: .ask, reason: "outside the amount cap", withinMandate: false)
        }
      }
    }

    switch contract.delegation {
    case .prepare:
      return RuleDecision(
        kind: .prepare, reason: "the rule prepares; the person confirms", withinMandate: true)
    case .ask:
      return RuleDecision(kind: .ask, reason: "the rule asks before it acts", withinMandate: true)
    case .autopilot:
      break
    }

    guard contract.isApproved, contract.approvedAt != nil else {
      return RuleDecision(kind: .ask, reason: "the rule is not approved yet", withinMandate: false)
    }

    guard let verbClass = verbClass(contract.action.verb) else {
      return RuleDecision(kind: .refuse, reason: "the action is not in the catalogue", withinMandate: false)
    }
    if verbClass == .commit {
      guard let read = consent ?? approvalConsent(contract) else {
        return RuleDecision(kind: .ask, reason: "a commit needs the person's word", withinMandate: false)
      }
      switch ConsentPolicy.decision(from: read, known: []) {
      case .proceed:
        return RuleDecision(kind: .run, reason: "the consent model cleared it", withinMandate: true)
      case .confirm:
        return RuleDecision(kind: .ask, reason: "high risk" , withinMandate: true)
      case .ask(let missing):
        return RuleDecision(
          kind: .ask, reason: "a detail is missing: \(missing)", withinMandate: true)
      }
    }

    return RuleDecision(
      kind: .run, reason: "class '\(verbClass.rawValue)' runs inside its mandate",
      withinMandate: true)
  }

  // MARK: Rendering

  /// The contract as one sentence a person can check before approving.
  static func sentence(for contract: RuleContract) -> String {
    var bits: [String] = []
    bits.append("When \(contract.trigger.kind.label.lowercased()) (\(contract.trigger.subject))")
    bits.append("do \(label(for: contract.action.verb).lowercased())")
    if !contract.protect.isEmpty { bits.append("protect \(contract.protect.joined(separator: ", "))") }
    if !contract.pauseWhen.isEmpty {
      bits.append("pause when \(contract.pauseWhen.joined(separator: ", "))")
    }
    bits.append("level: \(contract.delegation.rawValue)")
    if let cap = contract.mandate.amountCapMinor {
      bits.append("cap \(Money(minorUnits: cap, currency: Asset.all.first { $0.code == contract.mandate.currencyCode } ?? .usd).display)")
    }
    if let runs = contract.mandate.maxRuns { bits.append("up to \(runs) runs") }
    return bits.joined(separator: " → ") + "."
  }

  /// The rule as the document the conversation shows.
  static func document(for contract: RuleContract, date: Date = Date()) -> ReceiptSpec {
    var lines: [ReceiptLine] = [
      ReceiptLine(label: "When", value: "\(contract.trigger.kind.shortLabel) · \(contract.trigger.subject)", icon: "bolt"),
      ReceiptLine(label: "Do", value: label(for: contract.action.verb), icon: "wand.and.stars"),
    ]
    if contract.action.verb == "engine.reserve.share", let share = contract.action.sharePercent {
      lines.append(ReceiptLine(label: "Share", value: "\(Int(share))% of the money"))
    }
    lines.append(
      ReceiptLine(
        label: "Protect",
        value: contract.protect.isEmpty ? "Nothing named" : contract.protect.joined(separator: ", "),
        icon: "lock.shield"))
    lines.append(
      ReceiptLine(
        label: "Pause when",
        value: contract.pauseWhen.isEmpty ? "Nothing named" : contract.pauseWhen.joined(separator: ", "),
        icon: "pause.circle"))
    lines.append(ReceiptLine(label: "Level", value: contract.delegation.label, icon: "person.badge.key"))
    if let cap = contract.mandate.amountCapMinor {
      lines.append(
        ReceiptLine(
          label: "Cap",
          value: Money(
            minorUnits: cap,
            currency: Asset.all.first { $0.code == contract.mandate.currencyCode } ?? .usd
          ).display))
    }
    if let runs = contract.mandate.maxRuns {
      lines.append(ReceiptLine(label: "Runs", value: "\(contract.mandate.runsUsed) of \(runs) used"))
    }
    let footnote: String
    if contract.paused {
      footnote = "Paused. Nothing runs until you resume it."
    } else if contract.isApproved {
      footnote = "Approved. A commit still passes the same consent policy as everything else."
    } else {
      footnote = "Nothing runs until you approve this exact rule — not the sentence that proposed it."
    }
    return ReceiptSpec(
      kind: .brief,
      symbol: "gearshape.2",
      title: contract.trigger.kind.shortLabel,
      subtitle: sentence(for: contract),
      lines: lines,
      total: nil,
      reference: contract.isApproved ? "RULE" : "PROPOSED RULE",
      footnote: footnote,
      date: date)
  }

  // MARK: The app's own reader

  private static func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges > 1,
      let captured = Range(match.range(at: 1), in: text)
    else { return nil }
    let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    return value.count >= 2 ? value : nil
  }

  /// The event a sentence names, and its subject. Code, not a model.
  static func trigger(in message: String) -> RuleContract.Trigger? {
    let text = message
    if let payer =
      capture("every time\\s+([^,]{2,40}?)\\s+pays me", in: text)
      ?? capture("when(?:ever)?\\s+([^,]{2,40}?)\\s+pays me", in: text)
      ?? capture("payment (?:arrives )?from\\s+([^,]{2,40}?)(?:\\s|,|\\.|$)", in: text)
    {
      return RuleContract.Trigger(kind: .paymentReceived, subject: payer)
    }
    if let name =
      capture("when(?:ever)?\\s+(?:my\\s+)?([^,]{2,40}?)\\s+(?:charges|renews)", in: text)
      ?? capture("before\\s+(?:my\\s+)?([^,]{2,40}?)\\s+charges", in: text)
    {
      return RuleContract.Trigger(kind: .subscriptionCharge, subject: name)
    }
    if let item =
      capture("when the price of\\s+([^,]{2,60}?)\\s+(?:falls|drops)", in: text)
      ?? capture("the\\s+([^,]{2,60}?)\\s+claim window", in: text)
    {
      return RuleContract.Trigger(kind: .priceClaimWindow, subject: item)
    }
    if let subject =
      capture("when the watch on\\s+([^,]{2,60}?)\\s+(?:finds|drops|reports|returns)", in: text)
      ?? capture("when\\s+([^,]{2,60}?)\\s+drops below", in: text)
    {
      return RuleContract.Trigger(kind: .watchResult, subject: subject)
    }
    return nil
  }

  /// The action a sentence names. Only ids from the catalogue are returned.
  static func action(in message: String) -> RuleContract.Action? {
    let text = message.lowercased()
    func params() -> RuleContract.Action.Params? {
      let pattern = "(\\d{1,3}(?:[.,]\\d+)?)\\s*%"
      guard let raw = capture(pattern, in: message) else { return nil }
      let value = Double(raw.replacingOccurrences(of: ",", with: "."))
      guard let value, value > 0, value <= 100 else { return nil }
      return RuleContract.Action.Params(sharePercent: value, amountMinor: nil)
    }
    if text.contains("reserve") || text.contains("put it away") || text.contains("set it aside") {
      return RuleContract.Action(verb: "engine.reserve.share", params: params())
    }
    if text.contains("carve") || text.contains("tax") || text.contains("buffer") {
      return RuleContract.Action(verb: "engine.income.smooth", params: nil)
    }
    if text.contains("zombie") || text.contains("unused")
      || (text.contains("review") && (text.contains("subscription") || text.contains("charge")))
    {
      return RuleContract.Action(verb: "engine.subscriptions.review", params: nil)
    }
    if text.contains("claim") || text.contains("price match") || text.contains("price-match") {
      return RuleContract.Action(verb: "engine.price_claim.prepare", params: nil)
    }
    if text.contains("watch") { return RuleContract.Action(verb: "watch.create", params: nil) }
    if text.contains("research") || text.contains("find") || text.contains("compare") {
      return RuleContract.Action(verb: "task.create", params: nil)
    }
    if text.contains("send") || text.contains("transfer") || text.contains("pay") {
      return RuleContract.Action(verb: "transfer.prepare", params: nil)
    }
    if text.contains("cancel") { return RuleContract.Action(verb: "subscription.cancel", params: nil) }
    return nil
  }

  private static func protections(in message: String) -> [String] {
    let text = message.lowercased()
    var protect: [String] = []
    if text.contains("reserve") { protect.append("reserve") }
    if text.contains("plan") || text.contains("budget") || text.contains("allocation") {
      protect.append("plan")
    }
    if text.contains("goal") || text.contains("fund") || text.contains("trip") {
      protect.append("goal")
    }
    return protect
  }

  private static func pauses(in message: String) -> [String] {
    let text = message.lowercased()
    var pauses: [String] = []
    if text.contains("cap") || text.contains("up to") { pauses.append("amount_above_cap") }
    if text.contains("shortfall") || text.contains("break the plan") || text.contains("over budget") {
      pauses.append("plan_shortfall")
    }
    if text.contains("not arrived") || text.contains("hasn't arrived") || text.contains("pending") {
      pauses.append("income_not_arrived")
    }
    if text.contains("goal") || text.contains("protected") { pauses.append("goal_protected") }
    return pauses.isEmpty ? ["plan_shortfall"] : pauses
  }

  /// Read one sentence into a proposed contract. Returns nil when the sentence
  /// names no event or no action this app can honour. The result is never
  /// approved: the person approves the structure, not the sentence.
  static func propose(from message: String, now: Date = Date()) -> RuleContract? {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trigger = trigger(in: text), let action = action(in: text) else { return nil }
    let wantsAutopilot =
      text.range(
        of: "without asking|automatically|on its own|autopilot|just do it",
        options: [.regularExpression, .caseInsensitive]) != nil
    var contract = RuleContract(
      sentence: String(text.prefix(300)),
      trigger: trigger,
      action: action,
      protect: protections(in: text),
      pauseWhen: pauses(in: text),
      delegation: wantsAutopilot ? .autopilot : .prepare,
      proposedBy: "rules",
      createdAt: now)
    // A confident sentence never lifts a level: an autopilot the mandate cannot
    // carry is downgraded by code before the person ever sees it.
    if contract.delegation == .autopilot, !validate(contract).isEmpty {
      contract.delegation = .prepare
    }
    guard validate(contract).isEmpty else { return nil }
    return contract
  }

  /// Does this rule's trigger match the event that just fired?
  static func matches(_ contract: RuleContract, trigger: RuleContract.TriggerKind, subject: String) -> Bool {
    guard contract.trigger.kind == trigger else { return false }
    let named = contract.trigger.subject.lowercased()
    let fired = subject.lowercased()
    guard !named.isEmpty, !fired.isEmpty else { return false }
    return fired.contains(named) || named.contains(fired)
  }
}
