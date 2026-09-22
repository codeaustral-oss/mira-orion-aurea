import Foundation

// MARK: - Plan inputs

/// Every editable input to a plan, with the timestamp of its last change.
/// The brief requires the assumptions and the time of each input to be visible.
struct PlanInput: Hashable, Sendable, Codable {
  var value: Decimal
  var unit: String
  var updatedAt: Date
  var source: PlanInputSource

  enum PlanInputSource: String, Hashable, Sendable, Codable {
    /// Mira proposed it and the user has not overridden it.
    case miraSuggested
    /// The user edited it on the plan card.
    case userEdited
    /// Derived from the ledger rather than entered.
    case fromLedger

    var label: String {
      switch self {
      case .miraSuggested: return "Mira suggested"
      case .userEdited: return "You edited"
      case .fromLedger: return "From your accounts"
      }
    }
  }

  init(value: Decimal, unit: String, updatedAt: Date, source: PlanInputSource) {
    self.value = value
    self.unit = unit
    self.updatedAt = updatedAt
    self.source = source
  }
}

enum PlanStatus: Equatable, Sendable {
  case balanced
  /// The user's edits commit more than is available. Editable, not fabricated.
  case shortfall(Money)
  /// The plan is internally inconsistent (should not occur in normal use).
  case invalid(String)

  var isBalanced: Bool { self == .balanced }

  var headline: String {
    switch self {
    case .balanced: return "Every dollar has a job."
    case .shortfall(let amount): return "This plan is over by \(amount.display)."
    case .invalid(let reason): return reason
    }
  }

  var guidance: String? {
    switch self {
    case .balanced: return nil
    case .shortfall:
      return "Lower a figure or shorten the trip. Mira will not invent a balanced plan for you."
    case .invalid:
      return nil
    }
  }
}

// MARK: - Budget weeks

struct BudgetWeek: Identifiable, Hashable, Sendable {
  let index: Int
  let allowance: Money
  var spent: Money

  var id: Int { index }
  var remaining: Money { allowance - spent }

  init(index: Int, allowance: Money, spent: Money = .zero(.usd)) {
    self.index = index
    self.allowance = allowance
    self.spent = spent
  }
}

// MARK: - Allocation plan

/// A budget plan over cleared funds.
///
/// Allocations are **budget earmarks, not assets**. They are never added to the
/// balance again. The plan does not move money, does not invest, and approving
/// it does not authorize any external payment.
struct AllocationPlan: Hashable, Sendable {
  /// Cleared, spendable USD. Pending deposits are excluded upstream.
  var total: Money

  var knownBills: PlanInput
  var reserve: PlanInput
  var weeklyBudget: PlanInput
  var durationWeeks: Int
  var durationUpdatedAt: Date

  /// Accumulated settled spending sourced from the discretionary budget.
  var spentFromDiscretionary: Money

  /// Per-week spend, so "how much can I spend this week" is a lookup rather
  /// than an estimate.
  var weeks: [BudgetWeek]

  var isApproved: Bool
  var approvedAt: Date?
  var consentId: String?

  /// True when the plan was built from a ledger with only partial data.
  var basedOnPartialData: Bool

  init(
    total: Money,
    knownBills: PlanInput,
    reserve: PlanInput,
    weeklyBudget: PlanInput,
    durationWeeks: Int,
    durationUpdatedAt: Date,
    spentFromDiscretionary: Money = .zero(.usd),
    weeks: [BudgetWeek] = [],
    isApproved: Bool = false,
    approvedAt: Date? = nil,
    consentId: String? = nil,
    basedOnPartialData: Bool = false
  ) {
    self.total = total
    self.knownBills = knownBills
    self.reserve = reserve
    self.weeklyBudget = weeklyBudget
    self.durationWeeks = durationWeeks
    self.durationUpdatedAt = durationUpdatedAt
    self.spentFromDiscretionary = spentFromDiscretionary
    self.weeks = weeks
    self.isApproved = isApproved
    self.approvedAt = approvedAt
    self.consentId = consentId
    self.basedOnPartialData = basedOnPartialData
  }

  // MARK: Derived amounts

  var knownBillsMoney: Money {
    Money(majorUnits: knownBills.value, currency: .usd)
  }

  var reserveMoney: Money {
    Money(majorUnits: reserve.value, currency: .usd)
  }

  var weeklyBudgetMoney: Money {
    Money(majorUnits: weeklyBudget.value, currency: .usd)
  }

  /// The full discretionary envelope before any spending.
  var discretionaryBudget: Money {
    weeklyBudgetMoney * durationWeeks
  }

  /// What is left of the discretionary envelope after settled payments.
  var discretionaryRemaining: Money {
    discretionaryBudget - spentFromDiscretionary
  }

  /// Bills + reserve + remaining discretionary. These are earmarks, not assets.
  var committed: Money {
    knownBillsMoney + reserveMoney + discretionaryRemaining
  }

  /// Residual after earmarks. Derived, so the plan is always internally
  /// consistent: committed + unallocated == total.
  var unallocated: Money {
    total - committed
  }

  var status: PlanStatus {
    if knownBillsMoney.isNegative || reserveMoney.isNegative || weeklyBudgetMoney.isNegative {
      return .invalid("Amounts cannot be negative.")
    }
    if durationWeeks <= 0 {
      return .invalid("Choose a duration of at least one week.")
    }
    if unallocated.isNegative {
      return .shortfall(unallocated.magnitude)
    }
    return .balanced
  }

  /// Status phrasing that quotes the real total instead of a fixed string, so
  /// the sentence can never disagree with the ledger.
  var statusHeadline: String {
    switch status {
    case .balanced: return "All \(total.display) has a job."
    case .shortfall(let amount): return "This plan is over by \(amount.display)."
    case .invalid(let reason): return reason
    }
  }

  /// The four allocations, in the order the brief presents them. They sum
  /// exactly to `total` when the plan is balanced.
  var rows: [AllocationRow] {
    [
      AllocationRow(
        kind: .knownBills, label: "Known bills", amount: knownBillsMoney, isEditable: true),
      AllocationRow(kind: .reserve, label: "Reserve", amount: reserveMoney, isEditable: true),
      AllocationRow(
        kind: .discretionary,
        label: "\(durationWeeks) week\(durationWeeks == 1 ? "" : "s") of discretionary spending",
        amount: discretionaryRemaining,
        isEditable: true
      ),
      AllocationRow(
        kind: .unallocated, label: "Unallocated", amount: unallocated, isEditable: false),
    ]
  }

  /// Exact sum of the displayed rows. Used by the allocation invariant test.
  var rowsTotal: Money {
    rows.reduce(Money.zero(.usd)) { $0 + $1.amount }
  }

  /// Remaining budget for a week. This is a computed lookup; a language model
  /// never produces this number.
  func currentWeekRemaining(weekIndex: Int) -> Money? {
    weeks.first { $0.index == weekIndex }?.remaining
  }

  // MARK: Mutation

  /// Rebuilds the per-week allowances after any edit.
  mutating func rebuildWeeks() {
    let allowance = weeklyBudgetMoney
    var rebuilt: [BudgetWeek] = []
    for index in 1...max(durationWeeks, 1) {
      let existing = weeks.first { $0.index == index }
      rebuilt.append(
        BudgetWeek(index: index, allowance: allowance, spent: existing?.spent ?? .zero(.usd)))
    }
    // Carry over any week beyond the new duration so spending is never lost.
    for orphan in weeks where orphan.index > max(durationWeeks, 1) {
      rebuilt.append(orphan)
    }
    weeks = rebuilt
  }

  /// Records settled discretionary spending against the week it belongs to.
  mutating func recordSpend(_ amount: Money, weekIndex: Int) {
    spentFromDiscretionary = spentFromDiscretionary + amount
    if let idx = weeks.firstIndex(where: { $0.index == weekIndex }) {
      weeks[idx].spent = weeks[idx].spent + amount
    }
  }

  /// Marks an input as user-edited once it changes.
  mutating func edit(_ kind: AllocationRow.Kind, to value: Decimal, at date: Date) {
    switch kind {
    case .knownBills:
      knownBills.value = value
      knownBills.updatedAt = date
      knownBills.source = .userEdited
    case .reserve:
      reserve.value = value
      reserve.updatedAt = date
      reserve.source = .userEdited
    case .discretionary:
      weeklyBudget.value = value
      weeklyBudget.updatedAt = date
      weeklyBudget.source = .userEdited
      rebuildWeeks()
    case .unallocated:
      break
    }
  }

  /// Approval records explicit consent for this exact plan revision. It does
  /// not authorize an investment or an external payment.
  mutating func approve(at date: Date, consentId: String) {
    isApproved = true
    approvedAt = date
    self.consentId = consentId
  }
}

struct AllocationRow: Identifiable, Hashable, Sendable {
  enum Kind: String, Hashable, Sendable, CaseIterable, Identifiable {
    case knownBills, reserve, discretionary, unallocated

    var id: String { rawValue }
  }

  let kind: Kind
  let label: String
  let amount: Money
  let isEditable: Bool

  var id: String { kind.rawValue }

  /// Allocations are budget earmarks. This flag is what keeps the UI honest.
  var isBudgetEarmark: Bool { kind != .unallocated }

  var note: String? {
    switch kind {
    case .reserve:
      return "A user earmark, not a claim of legally protected or insured funds."
    case .discretionary:
      return "Covers local spending and the local payments you make from it."
    case .unallocated:
      return "Not yet given a job. Still yours."
    case .knownBills:
      return "Bills you told us about in advance."
    }
  }
}

// MARK: - Mira's starting proposal

extension AllocationPlan {
  /// The proposal Mira prepares from Journey A: USD 4,000 cleared, four weeks
  /// in Brazil, USD 1,200 of bills, USD 1,000 reserve, USD 300 per week.
  static func miraProposal(total: Money, now: Date = Date()) -> AllocationPlan {
    var plan = AllocationPlan(
      total: total,
      knownBills: PlanInput(value: 1200, unit: "USD", updatedAt: now, source: .miraSuggested),
      reserve: PlanInput(value: 1000, unit: "USD", updatedAt: now, source: .miraSuggested),
      weeklyBudget: PlanInput(value: 300, unit: "USD", updatedAt: now, source: .miraSuggested),
      durationWeeks: 4,
      durationUpdatedAt: now
    )
    plan.rebuildWeeks()
    return plan
  }
}
