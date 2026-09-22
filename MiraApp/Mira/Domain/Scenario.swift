import Foundation

// MARK: - Can I do this without breaking my plan?
//
// A purchase question is not "what should I buy" — it is arithmetic against the
// plan the app already holds. Three concrete scenarios, every figure taken from
// the plan's own rows, and every assumption stated:
//
//   · **buy now**   — which rows the money comes from, this week's budget first;
//   · **buy later** — waiting for the next allowance, or for pending income
//                     that has *not arrived* (and saying so);
//   · **change the goal** — what taking it from a protected fund does.
//
// There are no forecasts here the app cannot support: no projected income, no
// assumed raise, no rate the app does not own. When a scenario needs money the
// app cannot see, it says it does not fit instead of inventing it.

enum Affordability {
  enum Kind: String, Hashable, Sendable, CaseIterable {
    case buyNow = "buy_now"
    case buyLater = "buy_later"
    case changeGoal = "change_goal"

    var label: String {
      switch self {
      case .buyNow: return "Buy now"
      case .buyLater: return "Buy later"
      case .changeGoal: return "Change the goal"
      }
    }
  }

  /// One row's movement in a scenario. `delta` is signed: negative is money out.
  struct Effect: Hashable, Sendable {
    var row: String
    var before: Money
    var after: Money

    var delta: Money {
      Money(minorUnits: after.minorUnits - before.minorUnits, currency: before.currency)
    }

    /// "This week's budget USD 300.00 → USD 180.00 (−USD 120.00)".
    var line: String {
      let sign = delta.minorUnits > 0 ? "+" : (delta.minorUnits < 0 ? "−" : "")
      return "\(row) \(before.display) → \(after.display) (\(sign)\(delta.magnitude.display))"
    }
  }

  struct Scenario: Hashable, Sendable {
    var kind: Kind
    /// What this choice does, in one line.
    var headline: String
    var effects: [Effect]
    /// What the scenario assumes — including any reliance on money that has
    /// not arrived. Stated, never implied.
    var assumptions: [String]
    /// True when this choice can happen without breaking the plan.
    var works: Bool
  }

  struct Answer: Equatable, Sendable {
    var amount: Money
    var scenarios: [Scenario]
    var lead: String
    var document: ReceiptSpec
  }

  /// Convert a purchase amount into the plan's currency with the app's own
  /// table, stating the rate and its source. Nil when no rate is held.
  static func convert(
    _ amount: Money, to target: Asset, table: RateTable = .current
  ) -> (money: Money, assumption: String)? {
    if amount.currency == target { return (amount, "") }
    guard let rate = table.cross(from: amount.currency, to: target) else { return nil }
    let converted = Money(majorUnits: amount.majorUnits * rate, currency: target, rounding: .bankers)
    let source = table.isLive ? (table.ageLabel ?? "a fetched table") : "the reference table"
    let assumption =
      "Converted at 1 \(amount.currency.code) = \(DecimalFormatting.plain(rate, scale: 4)) "
      + "\(target.code) (\(source)); the plan's figures are \(target.code)."
    return (converted, assumption)
  }

  /// The three scenarios. Nil when the amount and the plan are in different
  /// currencies — a comparison the app will not fake.
  static func scenarios(
    amount: Money,
    plan: AllocationPlan,
    goal: Goal? = nil,
    pendingIncome: Money = .zero(.usd),
    weekIndex: Int,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Answer? {
    let currency = plan.total.currency
    guard amount.currency == currency, amount.minorUnits > 0 else { return nil }

    let week = max(
      0,
      plan.currentWeekRemaining(weekIndex: weekIndex)?.minorUnits
        ?? plan.weeklyBudgetMoney.minorUnits)
    let discretionary = max(0, plan.discretionaryRemaining.minorUnits)
    let reserve = max(0, plan.reserveMoney.minorUnits)
    let weeklyBudget = max(0, plan.weeklyBudgetMoney.minorUnits)
    let pending = pendingIncome.currency == currency ? max(0, pendingIncome.minorUnits) : 0
    let goalFund: (name: String, saved: Int64)? = {
      guard let goal, goal.currency == currency, goal.savedMinor > 0 else { return nil }
      return (goal.name, goal.savedMinor)
    }()

    func money(_ minor: Int64) -> Money { Money(minorUnits: minor, currency: currency) }
    func effect(_ row: String, _ before: Int64, _ after: Int64) -> Effect {
      Effect(row: row, before: money(before), after: money(after))
    }

    var scenarios: [Scenario] = []

    // ── Buy now ─────────────────────────────────────────────────────────────
    var nowEffects: [Effect] = []
    var nowAssumptions: [String] = []
    var nowWorks = true
    var nowHeadline: String
    if amount.minorUnits <= week {
      nowEffects = [effect("This week's budget", week, week - amount.minorUnits)]
      nowHeadline = "It fits this week — \(money(week - amount.minorUnits).display) would be left."
      nowAssumptions = [
        "Uses only what is left of this week's budget.",
        "Assumes no other unplanned spending this week.",
      ]
    } else if amount.minorUnits <= discretionary {
      let laterBefore = discretionary - week
      let laterAfter = laterBefore - (amount.minorUnits - week)
      nowEffects = [
        effect("This week's budget", week, 0),
        effect("Later weeks' allowances", laterBefore, laterAfter),
      ]
      nowHeadline =
        "It fits, but later weeks carry \(money(amount.minorUnits - week).display) of it."
      nowAssumptions = [
        "The rest comes out of the later weeks in this plan, not the reserve.",
        "Assumes no other unplanned spending before those weeks are used.",
      ]
    } else {
      let draw = amount.minorUnits - discretionary
      let fromReserve = min(draw, reserve)
      let stillShort = draw - fromReserve
      nowEffects = [
        effect("Later weeks' allowances", discretionary - week, 0),
        effect("Reserve", reserve, reserve - fromReserve),
      ]
      if stillShort > 0 {
        nowEffects.append(effect("Unallocated", 0, -stillShort))
      }
      nowWorks = stillShort == 0
      nowHeadline = stillShort == 0
        ? "It only fits by using \(money(fromReserve).display) of the reserve."
        : "It does not fit: even the whole reserve leaves \(money(stillShort).display) short."
      nowAssumptions = [
        "The reserve is an earmark, not spare money — using it breaks the plan's promise.",
      ]
    }
    if pending > 0, amount.minorUnits > week {
      nowAssumptions.append(
        "Does not count the pending \(money(pending).display) — that money has not arrived.")
    }
    scenarios.append(
      Scenario(
        kind: .buyNow, headline: nowHeadline, effects: nowEffects,
        assumptions: nowAssumptions, works: nowWorks))

    // ── Buy later ───────────────────────────────────────────────────────────
    var laterEffects: [Effect] = []
    var laterAssumptions: [String] = []
    var laterWorks = true
    var laterHeadline: String
    if pending >= amount.minorUnits {
      laterEffects = [effect("Pending income", pending, pending - amount.minorUnits)]
      laterHeadline = "Yes — once the pending \(money(pending).display) clears."
      laterAssumptions = [
        "Relies on income that has not arrived: \(money(pending).display) is pending, not available.",
        "Nothing is counted until it clears; the plan rows are untouched until then.",
      ]
    } else if weeklyBudget > 0 {
      let needed = max(0, amount.minorUnits - week)
      let weeks = max(1, Int(ceil(Double(needed) / Double(weeklyBudget))))
      let when = calendar.date(byAdding: .day, value: weeks * 7, to: now) ?? now
      let formatter = DateFormatter()
      formatter.dateFormat = "d MMMM"
      laterEffects = []
      laterHeadline =
        "Wait \(weeks) week\(weeks == 1 ? "" : "s") — from \(formatter.string(from: when)) the allowance covers it."
      laterAssumptions = [
        "Waits for \(weeks) week\(weeks == 1 ? "" : "s") of allowance; assumes you keep to the budget.",
        "No new money is assumed beyond the plan.",
      ]
    } else {
      laterWorks = false
      laterHeadline = "There is no weekly allowance to wait for, so I cannot say when it would fit."
      laterAssumptions = ["The plan has no weekly budget left to free up."]
    }
    if pending > 0, pending < amount.minorUnits {
      laterAssumptions.append(
        "The pending \(money(pending).display) alone is not enough; the rest comes from the plan.")
    }
    scenarios.append(
      Scenario(
        kind: .buyLater, headline: laterHeadline, effects: laterEffects,
        assumptions: laterAssumptions, works: laterWorks))

    // ── Change the goal ─────────────────────────────────────────────────────
    var goalEffects: [Effect] = []
    var goalAssumptions: [String] = []
    var goalWorks: Bool
    var goalHeadline: String
    if let fund = goalFund {
      if fund.saved >= amount.minorUnits {
        goalWorks = true
        goalEffects = [effect("Goal · \(fund.name)", fund.saved, fund.saved - amount.minorUnits)]
        goalHeadline =
          "Yes — if you accept moving \(fund.name) back by \(amount.display)."
        goalAssumptions = [
          "Takes \(amount.display) from the \(fund.name) fund; the reserve and this week's budget are untouched.",
          "The fund goes from \(money(fund.saved).display) to \(money(fund.saved - amount.minorUnits).display).",
        ]
      } else {
        goalWorks = false
        goalEffects = [effect("Goal · \(fund.name)", fund.saved, 0)]
        goalHeadline =
          "Not on its own — \(fund.name) holds \(money(fund.saved).display), "
          + "\(money(amount.minorUnits - fund.saved).display) short."
        goalAssumptions = ["Even emptying the fund leaves a shortfall."]
      }
    } else {
      goalWorks = false
      goalHeadline = "There is no protected goal on file to change."
      goalAssumptions = ["Changing a goal that is not on file is not a scenario I can price."]
    }
    scenarios.append(
      Scenario(
        kind: .changeGoal, headline: goalHeadline, effects: goalEffects,
        assumptions: goalAssumptions, works: goalWorks))

    let lead = "\(amount.display) against your plan — three ways it could work:"
    return Answer(
      amount: amount,
      scenarios: scenarios,
      lead: lead,
      document: document(amount: amount, scenarios: scenarios))
  }

  /// The three scenarios as the document the conversation shows: each choice
  /// with the rows it moves and its assumptions, so nothing is hidden in a
  /// sentence.
  static func document(amount: Money, scenarios: [Scenario]) -> ReceiptSpec {
    var lines: [ReceiptLine] = scenarios.map { scenario in
      ReceiptLine(
        label: scenario.kind.label,
        value: scenario.headline,
        icon: scenario.works ? "checkmark.circle" : "exclamationmark.triangle")
    }
    for scenario in scenarios {
      for effect in scenario.effects.prefix(2) {
        lines.append(
          ReceiptLine(
            label: "\(scenario.kind.label) · \(effect.row)",
            value: effect.line,
            icon: "arrow.left.arrow.right"))
      }
      for assumption in scenario.assumptions.prefix(1) {
        lines.append(ReceiptLine(label: "Assumes · \(scenario.kind.label)", value: assumption))
      }
    }
    return ReceiptSpec(
      kind: .brief,
      symbol: "arrow.triangle.branch",
      title: amount.display,
      subtitle: "Against this week's plan",
      lines: lines,
      total: nil,
      reference: "SCENARIOS",
      footnote: "The figures are your plan's own. Nothing here is booked or spent.",
      date: Date())
  }
}
