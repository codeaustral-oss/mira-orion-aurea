import Foundation

// MARK: - The income plan
//
// `IncomeSmoothing` already answers "what happens to one payment": tax first,
// then the buffer, then what can be spent. This extends it into the monthly
// allocation the essay draws — **reserve, confirmed bills and living costs,
// flexible spending, a goal** — computed from records the app already holds
// (bills, subscriptions, the plan's week budget, goals), editable row by row,
// and rendered as a document with a change-preview that says what each edit
// moves and what it leaves alone.
//
// The one arithmetic rule that cannot bend: the same money is never counted
// twice. The rows are disjoint parts of the income, `unallocated` is derived
// as income minus the rows, and an edit moves money from exactly one row to
// exactly one row. Reserve and spendable can never both claim the same unit.
//
// Approving records the allocation as the person's own; it moves nothing. The
// rows are earmarks, the same as the plan's.

extension IncomeSmoothing {
  /// One month of income, arranged as the four rows.
  struct MonthlyAllocation: Codable, Hashable, Sendable {
    /// The four rows, in the order the essay presents them.
    enum Row: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
      case reserve
      case bills
      case flexible
      case goal

      var id: String { rawValue }

      var label: String {
        switch self {
        case .reserve: return "Reserve"
        case .bills: return "Confirmed bills and living costs"
        case .flexible: return "Flexible spending"
        case .goal: return "Goal"
        }
      }

      /// Rows an edit does not silently dip into; the flexible row absorbs.
      var isProtected: Bool { self != .flexible }
    }

    var currencyCode: String
    var incomeMinor: Int64
    var reserveMinor: Int64
    var billsMinor: Int64
    var flexibleMinor: Int64
    var goalMinor: Int64
    /// The fund the goal row is for, when one is on file in this currency.
    var goalName: String?
    /// Records that could not join the rows because they are in another
    /// currency. Named, never converted across a rate the app does not own.
    var excludedRecords: [String] = []
    var updatedAt: Date
    var approvedAt: Date?

    var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }

    var income: Money { Money(minorUnits: incomeMinor, currency: currency) }
    var reserve: Money { Money(minorUnits: reserveMinor, currency: currency) }
    var bills: Money { Money(minorUnits: billsMinor, currency: currency) }
    var flexible: Money { Money(minorUnits: flexibleMinor, currency: currency) }
    var goal: Money { Money(minorUnits: goalMinor, currency: currency) }

    /// Every row added up. These are earmarks, never added to the balance again.
    var allocated: Money {
      Money(minorUnits: reserveMinor + billsMinor + flexibleMinor + goalMinor, currency: currency)
    }

    /// Income minus the rows. Zero on a balanced allocation, negative on an
    /// over-committed one — never clamped, so a shortfall stays visible.
    var unallocated: Money {
      Money(minorUnits: incomeMinor - allocated.minorUnits, currency: currency)
    }

    var isBalanced: Bool { unallocated.minorUnits == 0 }
    var isApproved: Bool { approvedAt != nil }

    func amount(_ row: Row) -> Money {
      switch row {
      case .reserve: return reserve
      case .bills: return bills
      case .flexible: return flexible
      case .goal: return goal
      }
    }

    /// The four rows plus the residual, in display order.
    var rows: [(row: Row, label: String, amount: Money, protected: Bool)] {
      [
        (.reserve, Row.reserve.label, reserve, true),
        (.bills, Row.bills.label, bills, true),
        (.flexible, Row.flexible.label, flexible, false),
        (.goal, goalName.map { "Goal · \($0)" } ?? Row.goal.label, goal, true),
      ]
    }

    /// "Every dollar has a job" or the shortfall, in the plan's own voice.
    var statusLine: String {
      if isBalanced { return "Every \(income.display) has a job." }
      if unallocated.isNegative {
        return "This month is over by \(unallocated.magnitude.display)."
      }
      return "\(unallocated.display) is not allocated yet."
    }

    // MARK: Editing, with a preview

    /// What one edit does: the rows it moves, the rows it leaves alone, and the
    /// allocation that would result. Pure — the caller decides whether to keep it.
    struct ChangePreview: Hashable, Sendable {
      struct Move: Hashable, Sendable {
        var row: Row
        var from: Money
        var to: Money
        var delta: Money { Money(minorUnits: to.minorUnits - from.minorUnits, currency: from.currency) }
      }

      var moves: [Move]
      var untouched: [Row]
      var after: MonthlyAllocation
      var line: String

      var balancedAfter: Bool { after.isBalanced }
    }

    /// Set one row, with the flexible row as the only absorber.
    ///
    /// Increasing a protected row takes the difference out of flexible;
    /// decreasing one gives it back to flexible. Editing flexible itself moves
    /// only flexible. The sum of the rows plus `unallocated` is income before
    /// and after, always — no unit is ever in two rows.
    func preview(_ row: Row, to value: Money, at date: Date = Date()) -> ChangePreview {
      precondition(
        value.currency == currency,
        "cannot allocate \(value.currency.code) inside a \(currencyCode) plan without an explicit conversion"
      )
      let target = max(0, value.minorUnits)
      var after = self
      after.updatedAt = date

      var moves: [ChangePreview.Move] = []
      func move(_ which: Row, from: Int64, to: Int64) {
        guard from != to else { return }
        moves.append(
          ChangePreview.Move(
            row: which,
            from: Money(minorUnits: from, currency: currency),
            to: Money(minorUnits: to, currency: currency)))
      }

      switch row {
      case .flexible:
        move(.flexible, from: flexibleMinor, to: target)
        after.flexibleMinor = target
      case .reserve, .bills, .goal:
        let current = amount(row).minorUnits
        let delta = target - current
        move(row, from: current, to: target)
        switch row {
        case .reserve: after.reserveMinor = target
        case .bills: after.billsMinor = target
        case .goal: after.goalMinor = target
        default: break
        }
        // The difference comes out of flexible, or goes back to it. When
        // flexible cannot cover an increase the residual goes negative: the
        // preview shows the shortfall instead of inventing money or letting a
        // row go below zero.
        let takenFromFlexible = delta > 0 ? min(delta, max(0, flexibleMinor)) : delta
        let flexibleAfter = flexibleMinor - takenFromFlexible
        move(.flexible, from: flexibleMinor, to: flexibleAfter)
        after.flexibleMinor = flexibleAfter
      }

      let untouched = Row.allCases.filter { which in
        !moves.contains { $0.row == which }
      }
      let untouchedText = untouched.isEmpty
        ? "Nothing else is touched."
        : "\(untouched.map(\.label).joined(separator: ", ")) stay\(untouched.count == 1 ? "s" : "") untouched."
      var line: String
      if moves.isEmpty {
        line = "Nothing changes — \(row.label) is already \(amount(row).display)."
      } else {
        let names = moves
          .map { move -> String in
            let direction = move.to.minorUnits > move.from.minorUnits ? "up" : "down"
            return "\(move.row.label) \(direction) \(move.delta.magnitude.display)"
          }
          .joined(separator: ", ")
        line = "\(names). \(untouchedText)"
      }
      if after.unallocated.isNegative {
        line += " This is over the month by \(after.unallocated.magnitude.display)."
      } else if !after.isBalanced {
        line += " \(after.unallocated.display) is not allocated yet."
      }
      return ChangePreview(moves: moves, untouched: untouched, after: after, line: line)
    }

    /// Apply a previewed edit. The preview is the change; this only commits it.
    mutating func apply(_ preview: ChangePreview) {
      self = preview.after
    }

    /// Approving records the allocation as the person's own. It moves nothing.
    mutating func approve(at date: Date = Date()) {
      approvedAt = date
      updatedAt = date
    }
  }
}

// MARK: - Building the proposal from records the app holds

extension IncomeSmoothing {
  /// The suggested reserve share of a month's income.
  static let suggestedReserveShare = Decimal(string: "0.20")!
  /// The suggested share for a goal, when one is on file in the same currency.
  static let suggestedGoalShare = Decimal(string: "0.10")!

  /// Assemble a monthly allocation from the records the app already holds.
  ///
  /// Every row is computed from something on file — the reserve and goal are
  /// the app's suggested shares, stated as suggestions; bills and subscriptions
  /// are the real records; flexible is the residual after the plan's own week
  /// budget × the weeks in the month. Records in another currency are named in
  /// `excludedRecords`, never converted and never summed.
  static func monthlyProposal(
    income: Money,
    bills: [Bill],
    subscriptions: [Subscription],
    weeklyBudget: Money,
    goals: [Goal],
    weeksPerMonth: Int = 4,
    now: Date = Date()
  ) -> MonthlyAllocation {
    let code = income.currency.code
    var excluded: [String] = []

    let billsInCurrency = bills.filter { $0.currencyCode == code }
    let subscriptionsInCurrency = subscriptions.filter { !$0.cancelled && $0.currencyCode == code }
    for bill in bills where bill.currencyCode != code {
      excluded.append("\(bill.name) (\(bill.currencyCode))")
    }
    for subscription in subscriptions where !subscription.cancelled && subscription.currencyCode != code {
      excluded.append("\(subscription.name) (\(subscription.currencyCode))")
    }

    let billsTotal = billsInCurrency.reduce(Int64(0)) { $0 + $1.amountMinor }
      + subscriptionsInCurrency.reduce(Int64(0)) { $0 + $1.monthly.minorUnits }

    func share(_ rate: Decimal) -> Int64 {
      NSDecimalNumber(decimal: Decimal(income.minorUnits) * rate).int64Value
    }

    let goal = goals.first { $0.currency.code == code }
    if weeklyBudget.currency.code != code, weeklyBudget.minorUnits > 0 {
      excluded.append("plan week budget (\(weeklyBudget.currency.code))")
    }

    let reserve = min(share(suggestedReserveShare), income.minorUnits)
    let goalShare = goal == nil ? 0 : min(share(suggestedGoalShare), max(0, income.minorUnits - reserve))
    let flexible = max(
      0,
      income.minorUnits - reserve - billsTotal - goalShare
    )

    return MonthlyAllocation(
      currencyCode: code,
      incomeMinor: income.minorUnits,
      reserveMinor: reserve,
      billsMinor: billsTotal,
      flexibleMinor: flexible,
      goalMinor: goalShare,
      goalName: goal?.name,
      excludedRecords: excluded,
      updatedAt: now,
      approvedAt: nil
    )
  }
}

// MARK: - The document

extension ReceiptSpec {
  /// The income plan as a document: the four rows, the residual, and the small
  /// print that says the rows are earmarks and who the figures came from.
  static func incomePlan(_ allocation: IncomeSmoothing.MonthlyAllocation, date: Date = Date()) -> ReceiptSpec {
    var lines: [ReceiptLine] = allocation.rows.map { entry in
      ReceiptLine(
        label: entry.label,
        value: entry.amount.display,
        icon: entry.protected ? "lock" : "slider.horizontal.3")
    }
    if !allocation.excludedRecords.isEmpty {
      lines.append(
        ReceiptLine(
          label: "Not counted here",
          value: allocation.excludedRecords.prefix(3).joined(separator: " · ")))
    }
    let footnote: String
    if allocation.isApproved {
      footnote = "Approved — the rows are earmarks, not transfers. "
        + "Nothing left the account; the reserve and the spending rows can never hold the same money."
    } else {
      footnote = "Proposed from your bills, subscriptions, week budget and goals. "
        + "Nothing is recorded until you approve it."
    }
    return ReceiptSpec(
      kind: .brief,
      symbol: "chart.bar.doc.horizontal",
      title: "\(allocation.income.display) a month",
      subtitle: allocation.goalName.map { "Reserve · bills · spending · \($0)" } ?? "Reserve · bills · spending · goal",
      lines: lines,
      total: ReceiptLine(
        label: allocation.isBalanced ? "Allocated" : "Not allocated",
        value: allocation.isBalanced ? allocation.allocated.display : allocation.unallocated.display),
      reference: allocation.isApproved ? "INCOME PLAN" : "PROPOSED",
      footnote: footnote,
      date: date)
  }
}
