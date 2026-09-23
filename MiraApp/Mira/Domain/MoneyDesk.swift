import Foundation

// MARK: - The money desk
//
// Twelve things a bank can do for a person that the market mostly does not,
// because they need an agent rather than a form: notice, compute, prepare, ask,
// and only then move money. Every engine here is deterministic — the arithmetic
// is the app's, no model picks a number — and every one ends in either an answer
// or a prepared action with one confirmation.

// MARK: 2 · Zombies and overlaps

/// A recurring charge nobody is using, or two that cover the same thing.
struct ZombieFinding: Sendable, Equatable, Identifiable {
  var id: String { "\(subscription.id)|\(reason)" }
  enum Reason: String, Sendable {
    case unused
    case duplicate
    case coveredByBundle

    var line: String {
      switch self {
      case .unused: return "not used in months"
      case .duplicate: return "you pay for this twice"
      case .coveredByBundle: return "already included in another plan"
      }
    }
  }

  var subscription: Subscription
  var reason: Reason
  var monthly: Money { subscription.monthly }
}

enum Zombies {
  /// What to look at, dearest first: an unused charge, an exact duplicate, or
  /// one a bundle the person already pays for covers.
  static func findings(_ subscriptions: [Subscription], now: Date = Date()) -> [ZombieFinding] {
    let active = subscriptions.filter { !$0.cancelled }
    var findings: [ZombieFinding] = []

    // Duplicates: the same service bought twice under different names.
    var seen: [String: Subscription] = [:]
    for subscription in active {
      let key = family(subscription.name)
      if let first = seen[key] {
        findings.append(ZombieFinding(subscription: subscription, reason: .duplicate))
        findings.append(ZombieFinding(subscription: first, reason: .duplicate))
      } else {
        seen[key] = subscription
      }
    }

    // Included in another plan the person pays for.
    let bundles: [(bundle: String, covers: [String])] = [
      ("Amazon Prime", ["prime video", "amazon music", "prime reading"]),
      ("iCloud+ 200 GB", ["apple tv+"]),
      ("YouTube Premium", ["youtube music"]),
    ]
    for subscription in active {
      let name = subscription.name.lowercased()
      for bundle in bundles where active.contains(where: { $0.name.caseInsensitiveCompare(bundle.bundle) == .orderedSame })
      {
        if bundle.covers.contains(where: { name.contains($0) }) {
          findings.append(ZombieFinding(subscription: subscription, reason: .coveredByBundle))
        }
      }
    }

    // Unused for months — the app's own record of last use.
    for subscription in active where subscription.lastUsedDaysAgo ?? 0 >= 60 {
      findings.append(ZombieFinding(subscription: subscription, reason: .unused))
    }

    return findings
      .sorted { $0.subscription.yearly.minorUnits > $1.subscription.yearly.minorUnits }
  }

  /// The family two subscriptions belong to, for duplicate detection.
  static func family(_ name: String) -> String {
    let lowered = name.lowercased()
    for family in ["netflix", "spotify", "disney", "max", "hbo", "youtube", "icloud", "adobe", "notion", "chatgpt", "smart fit", "ifood", "amazon"] where lowered.contains(family) {
      return family
    }
    return lowered.split(separator: " ").first.map(String.init) ?? lowered
  }

  /// What stopping all of them would save in a year.
  static func yearlySaving(_ findings: [ZombieFinding]) -> Money? {
    guard let currency = findings.first?.monthly.currency else { return nil }
    let minor = findings.reduce(Int64(0)) { $0 + $1.subscription.yearly.minorUnits }
    return Money(minorUnits: minor, currency: currency)
  }

  /// The card's own title: "1 quiet charge" is a charge; "3 quiet charges" is
  /// the plural. A count is never allowed to ride on a fixed plural.
  static func cardTitle(_ findings: [ZombieFinding]) -> String {
    "\(findings.count) quiet charge\(findings.count == 1 ? "" : "s")"
  }

  /// The answer line, with the grammar the count asks for. One item is stopped
  /// as "it"; several are stopped "all".
  static func answer(_ findings: [ZombieFinding], saving: Money?) -> String {
    guard let first = findings.first else { return "Nothing looks dead." }
    let subject = findings.count == 1 ? "1 to look at" : "\(findings.count) to look at"
    let stop = findings.count == 1 ? "Stopping it saves" : "Stopping them all saves"
    return "\(subject): \(first.subscription.name) \(first.reason.line). "
      + "\(stop) \(saving?.display ?? "—") a year."
  }

  /// Chips that lead somewhere real: cancelling the named charge, or reading
  /// the whole list. The cancel chip names the item the answer named.
  static func chips(_ findings: [ZombieFinding]) -> [String] {
    guard let first = findings.first else { return [] }
    return ["Cancel \(first.subscription.name)", "Show all subscriptions"]
  }
}

// MARK: 3 · Fee radar

/// A fee that was paid, and the rail that would have avoided it.
struct FeeEvent: Identifiable, Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable {
    case fx
    case atm
    case weekend
    case minimumBalance
    case transfer

    var label: String {
      switch self {
      case .fx: return "Currency conversion"
      case .atm: return "Cash withdrawal"
      case .weekend: return "Weekend transfer"
      case .minimumBalance: return "Falling under the minimum"
      case .transfer: return "Transfer fee"
      }
    }
  }

  var id: UUID = UUID()
  var kind: Kind
  var amountMinor: Int64
  var currencyCode: String
  var at: Date
  var note: String

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
}

enum FeeRadar {
  struct Finding: Sendable, Equatable {
    var kind: FeeEvent.Kind
    var total: Money
    var count: Int
    var advice: String
  }

  /// Fees grouped by kind, dearest first, each with the remedy the app can
  /// actually offer: the account's own FX mark-up (the number the tier screen
  /// prints), a larger single withdrawal, a weekday transfer, or the Pix rail.
  ///
  /// The advice is stated in the window's units — a total and a count of
  /// occurrences — never a monthly average beside a per-occurrence figure.
  static func findings(_ events: [FeeEvent], fxFeeLabel: String? = nil) -> [Finding] {
    let grouped = Dictionary(grouping: events) { "\($0.kind.rawValue):\($0.currencyCode)" }
    return grouped.compactMap { _, entries -> Finding? in
      guard let kind = entries.first?.kind else { return nil }
      guard let currency = entries.first?.currency else { return nil }
      let total = Money(minorUnits: entries.reduce(Int64(0)) { $0 + $1.amountMinor }, currency: currency)
      let remedy: String
      switch kind {
      case .fx:
        remedy = "each conversion carries the FX mark-up (\(fxFeeLabel ?? "your tier's rate"))"
      case .atm:
        remedy = "one larger withdrawal pays the fee once"
      case .weekend:
        remedy = "sending on a weekday avoids it"
      case .minimumBalance:
        remedy = "keeping the buffer in place avoids it"
      case .transfer:
        remedy = "the Pix rail costs nothing where it is supported"
      }
      let charges = entries.count == 1 ? "1 charge" : "\(entries.count) charges"
      return Finding(
        kind: kind, total: total, count: entries.count,
        advice: "\(charges) · \(total.display) — \(remedy).")
    }
    .sorted {
      if $0.total.currency == $1.total.currency {
        return $0.total.minorUnits > $1.total.minorUnits
      }
      return $0.total.currency.code < $1.total.currency.code
    }
  }

  static func totalsByCurrency(_ findings: [Finding]) -> [Money] {
    let grouped = Dictionary(grouping: findings, by: { $0.total.currency })
    return grouped.map { currency, rows in
      Money(minorUnits: rows.reduce(0) { $0 + $1.total.minorUnits }, currency: currency)
    }
    .sorted { $0.currency.code < $1.currency.code }
  }

  /// The answer: the window's total, then the biggest line and what would avoid
  /// it. One unit throughout — a three-month total and its occurrences.
  static func answer(total: Money, findings: [Finding]) -> String {
    guard let first = findings.first else { return "\(total.display) in fees." }
    return "\(total.display) in fees over three months. The biggest line is "
      + "\(first.kind.label): \(first.advice)"
  }

  static func answer(findings: [Finding]) -> String {
    let totals = totalsByCurrency(findings)
    guard !totals.isEmpty else { return "No fees are on record." }
    if totals.count == 1 { return answer(total: totals[0], findings: findings) }
    return totals.map(\.display).joined(separator: " and ")
      + " in fees over three months, shown separately by currency."
  }

  /// Chips that exist as app actions: the tier document names the FX mark-up,
  /// and balances are balances. The subscriptions list has nothing to do with a
  /// fees card.
  static let chips = ["Show my tier", "Show my balances"]
}

// MARK: 5 · Idle cash, with liquidity rules

enum IdleCash {
  struct Plan: Sendable, Equatable {
    var available: Money
    var billsDue: Money
    var subscriptionsDue: Money
    var weekBudget: Money
    var buffer: Money
    /// What can be put away without touching what is already promised.
    var safeToSweep: Money
    var reason: String
  }

  /// The arithmetic nobody does: what is left after everything already promised
  /// — this week's budget, the bills due, the subscriptions charging, and the
  /// buffer the person asked to keep.
  static func plan(
    available: Money,
    billsDue: Money,
    subscriptionsDue: Money,
    weekBudget: Money,
    buffer: Money
  ) -> Plan {
    let committed = billsDue.minorUnits + subscriptionsDue.minorUnits + weekBudget.minorUnits + buffer.minorUnits
    let safe = max(0, available.minorUnits - committed)
    return Plan(
      available: available, billsDue: billsDue, subscriptionsDue: subscriptionsDue,
      weekBudget: weekBudget, buffer: buffer,
      safeToSweep: Money(minorUnits: safe, currency: available.currency),
      reason: "\(billsDue.display) of bills, \(subscriptionsDue.display) of subscriptions, "
        + "\(weekBudget.display) for this week and your \(buffer.display) buffer are already spoken for.")
  }
}

// MARK: 6 · Income smoothing

enum IncomeSmoothing {
  struct Split: Sendable, Equatable {
    var received: Money
    var tax: Money
    var buffer: Money
    var spendable: Money
    var note: String
  }

  /// A freelancer's payment, carved the way it has to be: tax first, then the
  /// buffer the months without work need, and only then what can be spent.
  static func split(
    received: Money, taxRate: Decimal = Decimal(string: "0.15")!,
    bufferRate: Decimal = Decimal(string: "0.20")!
  ) -> Split {
    func portion(_ rate: Decimal) -> Money {
      Money(minorUnits: NSDecimalNumber(decimal: Decimal(received.minorUnits) * rate).int64Value,
            currency: received.currency)
    }
    let tax = portion(taxRate)
    let buffer = portion(bufferRate)
    let spendable = Money(
      minorUnits: received.minorUnits - tax.minorUnits - buffer.minorUnits, currency: received.currency)
    return Split(
      received: received, tax: tax, buffer: buffer, spendable: spendable,
      note: "Tax and buffer first — the months without work need the second one.")
  }
}

// MARK: 10 · Split & settle

/// A shared cost and who owes what.
struct SplitShare: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var person: String
  var amountMinor: Int64
  var settled: Bool = false

  var currencyCode: String = "BRL"
  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .brl }
  var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
}

struct SplitBill: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var title: String
  var totalMinor: Int64
  var currencyCode: String
  var shares: [SplitShare]
  var at: Date = Date()

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var total: Money { Money(minorUnits: totalMinor, currency: currency) }
  var outstanding: Money {
    Money(minorUnits: shares.filter { !$0.settled }.reduce(Int64(0)) { $0 + $1.amountMinor }, currency: currency)
  }
}

enum Splits {
  /// Even shares, with the odd cent going to the first people so the sum is
  /// exact — a split that does not add up is worse than an unfair cent.
  static func even(_ total: Money, among people: [String]) -> SplitBill {
    let names = people.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !names.isEmpty else {
      return SplitBill(title: "Split", totalMinor: total.minorUnits, currencyCode: total.currency.code, shares: [])
    }
    let base = total.minorUnits / Int64(names.count)
    let remainder = total.minorUnits % Int64(names.count)
    let shares = names.enumerated().map { index, name in
      SplitShare(
        person: name, amountMinor: base + (Int64(index) < remainder ? 1 : 0),
        currencyCode: total.currency.code)
    }
    return SplitBill(
      title: "Split", totalMinor: total.minorUnits, currencyCode: total.currency.code, shares: shares)
  }

  /// The people named after "with" / "between" / "among". The app never
  /// substitutes its own contacts for names it was not given: fewer than two
  /// people is a question, not a guess.
  static func people(in message: String) -> [String] {
    let after = message
      .range(of: "(?i)\\b(?:with|between|among)\\b", options: .regularExpression)
      .map { String(message[$0.upperBound...]) } ?? ""
    return after
      .replacingOccurrences(of: " and ", with: ",")
      .replacingOccurrences(of: " & ", with: ",")
      .components(separatedBy: CharacterSet(charactersIn: ",;"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0.count < 24 && $0.split(separator: " ").count <= 2 }
  }

  /// "Ana and Joao" / "Ana, Joao and Rui" — a list a person would say out loud.
  static func listPhrase(_ names: [String]) -> String {
    guard let last = names.last else { return "" }
    if names.count == 1 { return last }
    if names.count == 2 { return "\(names[0]) and \(last)" }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }

  /// What the answer says, and it has to agree with the card beside it.
  static func sentence(for split: SplitBill) -> String {
    let names = listPhrase(split.shares.map(\.person))
    let equal = Set(split.shares.map(\.amountMinor)).count == 1
    let each = equal ? " — \(split.shares.first?.amount.display ?? "") each." : "."
    return "Split \(split.total.display) between \(names)\(each)"
  }

  /// The read-back: the same shares and the same outstanding figure the card
  /// shows, from the record that was actually persisted.
  static func summary(for split: SplitBill) -> String {
    let shares = split.shares
      .map { "\($0.person) \($0.amount.display)\($0.settled ? " (paid)" : "")" }
      .joined(separator: ", ")
    let open = split.outstanding
    if open.minorUnits == 0 {
      return "\(split.total.display) split between \(listPhrase(split.shares.map(\.person))) — everyone is square."
    }
    return "\(split.total.display) split: \(shares). \(open.display) outstanding."
  }

  /// The split's document, built from the same record the answer reads.
  static func receipt(for split: SplitBill) -> ReceiptSpec {
    ReceiptSpec.brief(
      badge: "SPLIT", symbol: "person.2",
      title: split.title, subtitle: "\(split.shares.count) people",
      lines: split.shares.map {
        ReceiptLine(label: $0.person, value: $0.amount.display, icon: $0.settled ? "checkmark" : "person")
      },
      total: ReceiptLine(label: "Outstanding", value: split.outstanding.display),
      footnote: "Nothing is chased until you ask — say \"chase\" and I will.")
  }

  /// Chips that can actually settle something: one per open share, plus the
  /// read-back. A settled split offers nothing to settle.
  static func chips(for split: SplitBill) -> [String] {
    let open = split.shares.filter { !$0.settled }
    guard !open.isEmpty else { return ["Show my balances"] }
    return open.prefix(2).map { "\($0.person) paid me" } + ["Show the splits"]
  }
}

// MARK: 11 · Credit-building autopilot

enum CreditAutopilot {
  struct Instruction: Sendable, Equatable {
    var payBy: String
    var amount: Money
    var note: String
  }

  /// What to pay, and by when, to keep utilisation under a line without paying
  /// a cent more than needed.
  static func instruction(
    balance: Money, limit: Money, utilisationTarget: Decimal = Decimal(string: "0.30")!,
    statementDay: Int, now: Date = Date(), calendar: Calendar = .current
  ) -> Instruction {
    let targetMinor = NSDecimalNumber(decimal: Decimal(limit.minorUnits) * utilisationTarget).int64Value
    let over = max(0, balance.minorUnits - targetMinor)
    let pay = over > 0
      ? Money(minorUnits: over, currency: balance.currency)
      : Money(minorUnits: 0, currency: balance.currency)
    var components = calendar.dateComponents([.year, .month], from: now)
    components.day = min(max(statementDay - 3, 1), 28)
    let payDate = calendar.date(from: components) ?? now
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMMM"
    return Instruction(
      payBy: formatter.string(from: payDate),
      amount: pay,
      note: pay.minorUnits == 0
        ? "Already under \(NSDecimalNumber(decimal: utilisationTarget * 100).intValue)% of the limit — nothing to do."
        : "Paying this before the statement keeps you under \(NSDecimalNumber(decimal: utilisationTarget * 100).intValue)% of the limit.")
  }

  /// The answer sentence. A zero amount is stated as nothing due, not as
  /// "Pay BRL 0.00".
  static func lead(_ instruction: Instruction) -> String {
    guard instruction.amount.minorUnits > 0 else { return instruction.note }
    return "\(instruction.note) Pay \(instruction.amount.display) by \(instruction.payBy)."
  }

  /// The chips under the answer. There is no credit repayment rail in this
  /// build, so no chip offers to pay — least of all when the answer says
  /// nothing is due. The one chip is a real action: reading the balances.
  static func chips(amount: Money) -> [String] {
    _ = amount  // kept in the signature: whether a payment is due must not add a pay chip
    return ["Show my balances"]
  }
}

// MARK: 12 · Conversational fraud review

struct FlaggedCharge: Identifiable, Codable, Sendable, Equatable {
  var id: UUID = UUID()
  var merchant: String
  var amountMinor: Int64
  var currencyCode: String
  var at: Date
  var reason: String

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
}
