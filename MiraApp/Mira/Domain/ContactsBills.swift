import Foundation
import Observation

// MARK: - Contacts, bills, and everything the person owns
//
// The prototype shipped without a place for the user's own recipients or bills,
// which meant "known bills" was a number the plan imagined rather than a list the
// user owned. Since then this file has become the app's own record of the things
// a bank knows about someone: their contacts, their bills, their addresses,
// their cards' blocks, their subscriptions, their cashback, and the money desk's
// working notes.
//
// It is user-editable, persisted locally, and clearly distinct from any provider
// directory. Nothing here is a real payment instruction and nothing here is
// verified. A contact is a note-to-self with a name on it.

struct Contact: Identifiable, Codable, Hashable, Sendable {
  var id: UUID = UUID()
  var name: String
  var handle: String
  var note: String = ""
  var createdAt: Date = Date()
}

struct Bill: Identifiable, Codable, Hashable, Sendable {
  var id: UUID = UUID()
  var name: String
  /// Integer minor units in `currencyCode`, so a bill is exact.
  var amountMinor: Int64
  var currencyCode: String
  var dueDay: Int
  var createdAt: Date = Date()

  var currency: Asset { Asset.all.first { $0.code == currencyCode } ?? .usd }
  var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
}

/// The persisted directory file.
///
/// Lenient on purpose: this file is written by older builds of the app, and a
/// field added later must never make an existing directory unreadable. A
/// missing key is a default, never a wipe — the first version of this struct
/// reset the whole address book when one new key appeared.
struct LocalDirectoryPayload: Codable, Sendable {
  var version: Int = 1
  var contacts: [Contact] = []
  var bills: [Bill] = []
  var cardFrozen: Bool = false
  /// Delivery addresses the person saved, so a checkout never asks twice.
  var addresses: [Address] = []
  /// Standing approval: place orders like the last one without asking again,
  /// under the policy's limit. Off until the person turns it on.
  var autoCheckout: Bool = false
  /// The recurring charges the account carries.
  var subscriptions: [Subscription] = []
  /// Local only: whether the demo twelve were seeded into this file.
  var seededSubscriptions: Bool = false
  /// Cards with merchants blocked on them: last four → merchant names.
  var cardBlocks: [String: [String]] = [:]
  /// Remind me before each charge. On until the person says otherwise.
  var renewalReminders: Bool = true
  /// The day the last reminder was shown, so it is once a day, not once an open.
  var lastReminderDay: String?
  /// Cashback earned from offers, pending or credited.
  var cashback: [CashbackEntry] = []
  /// The day the account opened. The tier's one fact that is not already
  /// another record; a file written before this key existed leaves it unknown.
  var accountOpenedAt: Date?

  // The money desk's records.
  var feeEvents: [FeeEvent] = []
  var priceClaims: [PriceClaim] = []
  var negotiableBills: [NegotiableBill] = []
  var claimCases: [ClaimCase] = []
  var agentBudgets: [AgentBudget] = []
  var goals: [Goal] = []
  var cardPurchases: [JournalEntry] = []
  var lastOrder: PlacedOrder?
  var splits: [SplitBill] = []
  var flaggedCharges: [FlaggedCharge] = []
  var creditLimitMinor: Int64 = 0
  var creditBalanceMinor: Int64 = 0
  var statementDay: Int = 22
  var seededDesk: Bool = false
  /// The standing rules the person approved: when → do → protect → pause.
  var rules: [RuleContract] = []
  /// The monthly allocation: reserve, bills, flexible spending, a goal.
  var incomePlan: IncomeSmoothing.MonthlyAllocation?
  /// The profile whose records this file holds. Nil means a file written
  /// before profiles existed; the session reseeds it on first open.
  var personaSlug: String?

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
    contacts = ((try? c.decodeIfPresent([Contact].self, forKey: .contacts)) ?? nil) ?? []
    bills = ((try? c.decodeIfPresent([Bill].self, forKey: .bills)) ?? nil) ?? []
    cardFrozen = ((try? c.decodeIfPresent(Bool.self, forKey: .cardFrozen)) ?? nil) ?? false
    addresses = ((try? c.decodeIfPresent([Address].self, forKey: .addresses)) ?? nil) ?? []
    autoCheckout = ((try? c.decodeIfPresent(Bool.self, forKey: .autoCheckout)) ?? nil) ?? false
    subscriptions = ((try? c.decodeIfPresent([Subscription].self, forKey: .subscriptions)) ?? nil) ?? []
    seededSubscriptions = ((try? c.decodeIfPresent(Bool.self, forKey: .seededSubscriptions)) ?? nil) ?? false
    cardBlocks = ((try? c.decodeIfPresent([String: [String]].self, forKey: .cardBlocks)) ?? nil) ?? [:]
    renewalReminders = ((try? c.decodeIfPresent(Bool.self, forKey: .renewalReminders)) ?? nil) ?? true
    lastReminderDay = ((try? c.decodeIfPresent(String.self, forKey: .lastReminderDay)) ?? nil)
    cashback = ((try? c.decodeIfPresent([CashbackEntry].self, forKey: .cashback)) ?? nil) ?? []
    accountOpenedAt = ((try? c.decodeIfPresent(Date.self, forKey: .accountOpenedAt)) ?? nil)
    feeEvents = ((try? c.decodeIfPresent([FeeEvent].self, forKey: .feeEvents)) ?? nil) ?? []
    priceClaims = ((try? c.decodeIfPresent([PriceClaim].self, forKey: .priceClaims)) ?? nil) ?? []
    negotiableBills = ((try? c.decodeIfPresent([NegotiableBill].self, forKey: .negotiableBills)) ?? nil) ?? []
    claimCases = ((try? c.decodeIfPresent([ClaimCase].self, forKey: .claimCases)) ?? nil) ?? []
    agentBudgets = ((try? c.decodeIfPresent([AgentBudget].self, forKey: .agentBudgets)) ?? nil) ?? []
    goals = ((try? c.decodeIfPresent([Goal].self, forKey: .goals)) ?? nil) ?? []
    cardPurchases = ((try? c.decodeIfPresent([JournalEntry].self, forKey: .cardPurchases)) ?? nil) ?? []
    lastOrder = (try? c.decodeIfPresent(PlacedOrder.self, forKey: .lastOrder)) ?? nil
    splits = ((try? c.decodeIfPresent([SplitBill].self, forKey: .splits)) ?? nil) ?? []
    flaggedCharges = ((try? c.decodeIfPresent([FlaggedCharge].self, forKey: .flaggedCharges)) ?? nil) ?? []
    creditLimitMinor = ((try? c.decodeIfPresent(Int64.self, forKey: .creditLimitMinor)) ?? nil) ?? 0
    creditBalanceMinor = ((try? c.decodeIfPresent(Int64.self, forKey: .creditBalanceMinor)) ?? nil) ?? 0
    statementDay = ((try? c.decodeIfPresent(Int.self, forKey: .statementDay)) ?? nil) ?? 22
    seededDesk = ((try? c.decodeIfPresent(Bool.self, forKey: .seededDesk)) ?? nil) ?? false
    rules = ((try? c.decodeIfPresent([RuleContract].self, forKey: .rules)) ?? nil) ?? []
    incomePlan = ((try? c.decodeIfPresent(IncomeSmoothing.MonthlyAllocation.self, forKey: .incomePlan)) ?? nil)
    personaSlug = (try? c.decodeIfPresent(String.self, forKey: .personaSlug)) ?? nil
  }
}

/// A small, local, user-owned store.
@Observable
final class LocalDirectoryStore {
  private(set) var contacts: [Contact] = []
  private(set) var bills: [Bill] = []
  private(set) var addresses: [Address] = []
  private(set) var autoCheckout: Bool = false
  private(set) var subscriptions: [Subscription] = []
  private(set) var seededSubscriptions: Bool = false
  private(set) var cardBlocks: [String: [String]] = [:]
  private(set) var renewalReminders: Bool = true
  private(set) var lastReminderDay: String?
  private(set) var cashback: [CashbackEntry] = []
  private(set) var accountOpenedAt: Date?
  private(set) var feeEvents: [FeeEvent] = []
  private(set) var priceClaims: [PriceClaim] = []
  private(set) var negotiableBills: [NegotiableBill] = []
  private(set) var claimCases: [ClaimCase] = []
  private(set) var agentBudgets: [AgentBudget] = []
  private(set) var goals: [Goal] = []
  private(set) var cardPurchases: [JournalEntry] = []
  private(set) var lastOrder: PlacedOrder?
  private(set) var splits: [SplitBill] = []
  private(set) var flaggedCharges: [FlaggedCharge] = []
  private(set) var creditLimitMinor: Int64 = 0
  private(set) var creditBalanceMinor: Int64 = 0
  private(set) var statementDay: Int = 22
  private(set) var seededDesk: Bool = false
  private(set) var rules: [RuleContract] = []
  private(set) var incomePlan: IncomeSmoothing.MonthlyAllocation?
  /// The profile whose records these are. The session compares it with the
  /// profile it is opening as, and reseeds when they differ.
  private(set) var personaSlug: String?
  private(set) var cardFrozen: Bool = false
  private(set) var lastError: String?

  @ObservationIgnored private let path: URL

  init(path: URL? = nil) {
    self.path = path ?? LocalDirectoryStore.defaultPath()
    load()
  }

  static func defaultPath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Mira", isDirectory: true)
      .appendingPathComponent("directory.json")
  }

  // MARK: Contacts

  func addContact(name: String, handle: String, note: String = "") {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else {
      lastError = "A contact needs a name."
      return
    }
    contacts.append(
      Contact(name: cleaned, handle: handle.trimmingCharacters(in: .whitespacesAndNewlines), note: note))
    persist()
  }

  func updateContact(_ contact: Contact) {
    guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
    contacts[index] = contact
    persist()
  }

  func removeContact(_ id: UUID) {
    contacts.removeAll { $0.id == id }
    persist()
  }

  // MARK: Bills

  func addBill(name: String, amount: Money, dueDay: Int) {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, amount.minorUnits > 0 else {
      lastError = "A bill needs a name and an amount."
      return
    }
    bills.append(
      Bill(
        name: cleaned, amountMinor: amount.minorUnits, currencyCode: amount.currency.code,
        dueDay: min(max(dueDay, 1), 28)))
    persist()
  }

  func updateBill(_ bill: Bill) {
    guard let index = bills.firstIndex(where: { $0.id == bill.id }) else { return }
    bills[index] = bill
    persist()
  }

  func removeBill(_ id: UUID) {
    bills.removeAll { $0.id == id }
    persist()
  }

  /// The user's own known-bills total, in USD only when every bill is USD.
  /// Mixed currencies are reported as a per-currency list rather than summed
  /// across rates the app does not own.
  var billsByCurrency: [(currency: Asset, total: Money)] {
    let grouped = Dictionary(grouping: bills, by: { $0.currencyCode })
    return grouped.keys.sorted().compactMap { code in
      guard let asset = Asset.all.first(where: { $0.code == code }) else { return nil }
      let total = grouped[code, default: []].reduce(Int64(0)) { $0 + $1.amountMinor }
      return (asset, Money(minorUnits: total, currency: asset))
    }
  }

  // MARK: Addresses

  /// Save a delivery address. One main address at a time: marking a new one main
  /// clears the flag from the last, so checkout always has a single default.
  @discardableResult
  func saveAddress(_ text: String, makeMain: Bool = false) -> Address? {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else {
      lastError = "An address needs a street or a place."
      return nil
    }
    if let existing = addresses.first(where: { $0.text.caseInsensitiveCompare(cleaned) == .orderedSame }) {
      if makeMain { setMainAddress(existing.id) }
      return addresses.first { $0.id == existing.id }
    }
    let address = Address(text: cleaned, isMain: makeMain || addresses.isEmpty, addedAt: Date())
    addresses.append(address)
    persist()
    return address
  }

  func setMainAddress(_ id: UUID) {
    for index in addresses.indices {
      addresses[index].isMain = addresses[index].id == id
    }
    persist()
  }

  func removeAddress(_ id: UUID) {
    addresses.removeAll { $0.id == id }
    if !addresses.contains(where: { $0.isMain }), !addresses.isEmpty {
      addresses[0].isMain = true
    }
    persist()
  }

  var mainAddress: Address? { addresses.first { $0.isMain } }

  // MARK: Standing approval

  /// Standing approval, on or off. Kept next to the address and card it uses.
  func setAutoCheckout(_ enabled: Bool) {
    autoCheckout = enabled
    persist()
  }

  // MARK: Subscriptions

  func addSubscription(_ subscription: Subscription) {
    subscriptions.append(subscription)
    persist()
  }

  func updateSubscription(_ subscription: Subscription) {
    guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
    subscriptions[index] = subscription
    persist()
  }

  /// Mark it cancelled here and now, and block the merchant on the card that
  /// pays it: the app's own record is the fact it can act on, and a blocked
  /// merchant stops the charge even if the platform keeps trying.
  func cancelSubscription(_ id: UUID) {
    guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
    subscriptions[index].cancelled = true
    if let card = subscriptions[index].cardLast4 {
      blockMerchant(subscriptions[index].name, on: card)
    }
    persist()
  }

  func restoreSubscription(_ id: UUID) {
    guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
    subscriptions[index].cancelled = false
    if let card = subscriptions[index].cardLast4 {
      unblockMerchant(subscriptions[index].name, on: card)
    }
    persist()
  }

  // MARK: Card

  func setCardFrozen(_ frozen: Bool) {
    cardFrozen = frozen
    persist()
  }

  // MARK: Card blocks

  /// Block one merchant on one card. The charge is declined at the card, which
  /// is a thing a bank can do and a cancellation form cannot.
  func blockMerchant(_ merchant: String, on cardLast4: String) {
    let cleaned = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, !cardLast4.isEmpty else { return }
    var blocked = cardBlocks[cardLast4] ?? []
    guard !blocked.contains(cleaned) else { return }
    blocked.append(cleaned)
    cardBlocks[cardLast4] = blocked
    persist()
  }

  func unblockMerchant(_ merchant: String, on cardLast4: String) {
    guard var blocked = cardBlocks[cardLast4] else { return }
    blocked.removeAll { $0.caseInsensitiveCompare(merchant) == .orderedSame }
    if blocked.isEmpty { cardBlocks[cardLast4] = nil } else { cardBlocks[cardLast4] = blocked }
    persist()
  }

  func blockedMerchants(on cardLast4: String) -> [String] {
    cardBlocks[cardLast4] ?? []
  }

  /// Is this merchant blocked on the card that pays it?
  func isBlocked(_ merchant: String, on cardLast4: String?) -> Bool {
    guard let cardLast4 else { return false }
    return blockedMerchants(on: cardLast4).contains { $0.caseInsensitiveCompare(merchant) == .orderedSame }
  }

  /// Charges stopped at the card while they were still expected. A block that
  /// followed a cancellation is housekeeping, so it is not counted here — the
  /// tier reads this as the months the card had to say no.
  var blockedChargeCount: Int {
    cardBlocks.reduce(0) { count, entry in
      let cancelled = subscriptions
        .filter { $0.cancelled && $0.cardLast4 == entry.key }
        .map { $0.name.lowercased() }
      return count + entry.value.filter { !cancelled.contains($0.lowercased()) }.count
    }
  }

  // MARK: Cashback

  func recordCashback(_ entry: CashbackEntry) {
    cashback.append(entry)
    persist()
  }

  /// Credit everything pending and say how much moved.
  @discardableResult
  func creditPendingCashback() -> Int64 {
    var credited: Int64 = 0
    for index in cashback.indices where !cashback[index].credited {
      cashback[index].credited = true
      credited += cashback[index].earnedMinor
    }
    if credited > 0 { persist() }
    return credited
  }

  // MARK: Renewal reminders

  func setRenewalReminders(_ enabled: Bool) {
    renewalReminders = enabled
    persist()
  }

  /// Marks the day a reminder was shown, so opening the app five times does not
  /// produce five reminders.
  func noteReminderShown(day: String) {
    lastReminderDay = day
    persist()
  }

  // MARK: The money desk

  func savePriceClaim(_ claim: PriceClaim) {
    if let index = priceClaims.firstIndex(where: { $0.id == claim.id }) {
      priceClaims[index] = claim
    } else {
      priceClaims.append(claim)
    }
    persist()
  }

  func saveClaimCase(_ claim: ClaimCase) {
    if let index = claimCases.firstIndex(where: { $0.id == claim.id }) {
      claimCases[index] = claim
    } else {
      claimCases.append(claim)
    }
    persist()
  }

  func saveSplit(_ split: SplitBill) {
    if let index = splits.firstIndex(where: { $0.id == split.id }) {
      splits[index] = split
    } else {
      splits.append(split)
    }
    persist()
  }

  func settleSplitShare(_ id: UUID, person: String) {
    guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
    guard let share = splits[index].shares.firstIndex(where: { $0.person == person }) else { return }
    splits[index].shares[share].settled = true
    persist()
  }

  func saveAgentBudget(_ budget: AgentBudget) {
    if let index = agentBudgets.firstIndex(where: { $0.id == budget.id }) {
      agentBudgets[index] = budget
    } else {
      agentBudgets.append(budget)
    }
    persist()
  }

  func spend(_ amount: Money, from agent: String, note: String) {
    guard let index = agentBudgets.firstIndex(where: { $0.agent.caseInsensitiveCompare(agent) == .orderedSame })
    else { return }
    agentBudgets[index].spentMinor += amount.minorUnits
    agentBudgets[index].receipts.append(note)
    persist()
  }

  func saveGoal(_ goal: Goal) {
    if let index = goals.firstIndex(where: { $0.id == goal.id }) {
      goals[index] = goal
    } else {
      goals.append(goal)
    }
    persist()
  }

  func saveCardPurchase(_ entry: JournalEntry, order: PlacedOrder) {
    guard !cardPurchases.contains(where: { $0.idempotencyKey == entry.idempotencyKey }) else { return }
    cardPurchases.append(entry)
    lastOrder = order
    persist()
  }

  func updateLastOrder(_ order: PlacedOrder) {
    lastOrder = order
    persist()
  }

  func resolveFlaggedCharge(_ id: UUID) {
    flaggedCharges.removeAll { $0.id == id }
    persist()
  }

  // MARK: The rule contract

  /// Save a rule, approved or proposed. The store never approves on its own:
  /// approval is a separate act on the exact structured contract.
  func saveRule(_ rule: RuleContract) {
    if let index = rules.firstIndex(where: { $0.id == rule.id }) {
      rules[index] = rule
    } else {
      rules.append(rule)
    }
    persist()
  }

  func removeRule(_ id: UUID) {
    rules.removeAll { $0.id == id }
    persist()
  }

  func approveRule(_ id: UUID, at date: Date = Date()) {
    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
    rules[index].isApproved = true
    rules[index].approvedAt = date
    rules[index].paused = false
    persist()
  }

  func setRulePaused(_ id: UUID, paused: Bool) {
    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
    rules[index].paused = paused
    persist()
  }

  /// One run is on the record, so the run count is a fact the mandate reads.
  func noteRuleRun(_ id: UUID) {
    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
    rules[index].mandate.runsUsed += 1
    persist()
  }

  // MARK: The income plan

  func saveIncomePlan(_ plan: IncomeSmoothing.MonthlyAllocation) {
    incomePlan = plan
    persist()
  }

  /// Approving records the allocation. It moves nothing.
  func approveIncomePlan(at date: Date = Date()) {
    guard var plan = incomePlan else { return }
    plan.approve(at: date)
    incomePlan = plan
    persist()
  }

  // MARK: Demo data
  //
  // The demo account carries these the way it carries the twelve
  // subscriptions: as the person's own data, seeded once, editable, and never
  // re-added after a person removes one.

  static func demoFees(now: Date = Date()) -> [FeeEvent] {
    func daysAgo(_ days: Int) -> Date { Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now }
    return [
      FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "BRL", at: daysAgo(6), note: "Card spend in euros"),
      FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "BRL", at: daysAgo(21), note: "Card spend in dollars"),
      FeeEvent(kind: .fx, amountMinor: 1_840, currencyCode: "BRL", at: daysAgo(48), note: "Card spend in euros"),
      FeeEvent(kind: .atm, amountMinor: 2_490, currencyCode: "BRL", at: daysAgo(12), note: "Withdrawal at an ATM"),
      FeeEvent(kind: .atm, amountMinor: 2_490, currencyCode: "BRL", at: daysAgo(40), note: "Withdrawal abroad"),
      FeeEvent(kind: .weekend, amountMinor: 990, currencyCode: "BRL", at: daysAgo(9), note: "Transfer sent on a Sunday"),
      FeeEvent(kind: .transfer, amountMinor: 490, currencyCode: "BRL", at: daysAgo(33), note: "Instant transfer"),
    ]
  }

  static func demoBills(now: Date = Date()) -> [NegotiableBill] {
    [
      NegotiableBill(
        name: "Internet Fibra 600 MB", monthlyMinor: 19_990, currencyCode: "BRL", renewalInDays: 12,
        competitor: "Vivo Fibra", competitorMonthlyMinor: 14_990)
    ]
  }

  static func demoGoals(now: Date = Date()) -> [Goal] {
    [
      Goal(
        name: "Lisbon trip", targetMinor: 400_000, savedMinor: 120_000, currencyCode: "BRL",
        protected: true)
    ]
  }

  static func demoFlags(now: Date = Date()) -> [FlaggedCharge] {
    [
      FlaggedCharge(
        merchant: "UNKNOWN*LOJA-99", amountMinor: 8_990, currencyCode: "BRL",
        at: Calendar.current.date(byAdding: .hour, value: -9, to: now) ?? now,
        reason: "A merchant you have never used, at 3:12 in the morning.")
    ]
  }

  // MARK: Profiles
  //
  // A profile is the whole session. The store belongs to the person who is
  // signed in, so choosing one replaces the records rather than merging them:
  // switching twice must never accumulate a second copy of a subscription, a
  // goal or a bill. Everything the persona carries is written, including the
  // empty lists — a profile without a flagged charge must not inherit the last
  // person's.

  func reseed(for persona: DemoPersona, now: Date = Date()) {
    personaSlug = persona.id
    contacts = []
    bills = []
    addresses = []
    autoCheckout = false
    subscriptions = persona.subscriptions
    seededSubscriptions = true
    cardBlocks = [:]
    renewalReminders = true
    lastReminderDay = nil
    cashback = []
    accountOpenedAt =
      Calendar.current.date(byAdding: .month, value: -persona.accountOpenedMonthsAgo, to: now) ?? now
    feeEvents = persona.fees
    priceClaims = []
    negotiableBills = persona.bills
    claimCases = []
    agentBudgets = []
    goals = persona.goals
    cardPurchases = []
    lastOrder = nil
    splits = []
    flaggedCharges = persona.flagged
    creditLimitMinor = persona.creditLimitMinor
    creditBalanceMinor = persona.creditBalanceMinor
    statementDay = persona.statementDay
    seededDesk = true
    rules = []
    incomePlan = nil
    cardFrozen = persona.cardFrozen
    persist()
  }

  // MARK: Persistence

  private func load() {
    do {
      let data = try Data(contentsOf: path)
      let payload = try JSONDecoder().decode(LocalDirectoryPayload.self, from: data)
      contacts = payload.contacts
      bills = payload.bills
      addresses = payload.addresses
      autoCheckout = payload.autoCheckout
      subscriptions = payload.subscriptions
      seededSubscriptions = payload.seededSubscriptions
      cardBlocks = payload.cardBlocks
      renewalReminders = payload.renewalReminders
      lastReminderDay = payload.lastReminderDay
      cashback = payload.cashback
      accountOpenedAt = payload.accountOpenedAt
      feeEvents = payload.feeEvents
      priceClaims = payload.priceClaims
      negotiableBills = payload.negotiableBills
      claimCases = payload.claimCases
      agentBudgets = payload.agentBudgets
      goals = payload.goals
      cardPurchases = payload.cardPurchases
      lastOrder = payload.lastOrder
      splits = payload.splits
      flaggedCharges = payload.flaggedCharges
      creditLimitMinor = payload.creditLimitMinor
      creditBalanceMinor = payload.creditBalanceMinor
      statementDay = payload.statementDay
      seededDesk = payload.seededDesk
      cardFrozen = payload.cardFrozen
      rules = payload.rules
      incomePlan = payload.incomePlan
      personaSlug = payload.personaSlug
      seedDemoDataIfNeeded()
    } catch {
      // A missing file is the normal first-run case, not an error.
      if (error as NSError).code != NSFileReadNoSuchFileError {
        lastError = "The local directory could not be read. Starting empty."
      }
      contacts = []
      bills = []
      addresses = []
      autoCheckout = false
      cardFrozen = false
      subscriptions = []
      seededSubscriptions = false
      accountOpenedAt = nil
      seedDemoDataIfNeeded()
    }
  }

  /// The demo account's own data: seeded once, never re-added after a person
  /// deletes one.
  private func seedDemoDataIfNeeded() {
    var changed = false
    // The prototype's account carries the history the seed implies — twelve
    // subscriptions, a ledger with two weeks in it. Its opening date is part
    // of that furniture, so a file written before the key existed keeps the
    // same standing rather than dropping to Base.
    if accountOpenedAt == nil {
      accountOpenedAt = Calendar.current.date(byAdding: .month, value: -7, to: Date())
      changed = true
    }
    // A subscription saved before the app recorded last use: the demo two that
    // nobody has opened in months get their dates back.
    for index in subscriptions.indices where subscriptions[index].lastUsedDaysAgo == nil {
      let name = subscriptions[index].name.lowercased()
      if name.contains("max") { subscriptions[index].lastUsedDaysAgo = 96; changed = true }
      if name.contains("notion") { subscriptions[index].lastUsedDaysAgo = 71; changed = true }
    }
    if subscriptions.isEmpty && !seededSubscriptions {
      subscriptions = Subscriptions.demoSeed()
      seededSubscriptions = true
      changed = true
    }
    if !seededDesk {
      if feeEvents.isEmpty { feeEvents = Self.demoFees() }
      if negotiableBills.isEmpty { negotiableBills = Self.demoBills() }
      if goals.isEmpty { goals = Self.demoGoals() }
      if flaggedCharges.isEmpty { flaggedCharges = Self.demoFlags() }
      if creditLimitMinor == 0 {
        creditLimitMinor = 800_000
        creditBalanceMinor = 210_000
      }
      seededDesk = true
      changed = true
    }
    if changed { persist() }
  }

  private func persist() {
    var payload = LocalDirectoryPayload()
    payload.contacts = contacts
    payload.bills = bills
    payload.cardFrozen = cardFrozen
    payload.addresses = addresses
    payload.autoCheckout = autoCheckout
    payload.subscriptions = subscriptions
    payload.seededSubscriptions = seededSubscriptions
    payload.cardBlocks = cardBlocks
    payload.renewalReminders = renewalReminders
    payload.lastReminderDay = lastReminderDay
    payload.cashback = cashback
    payload.accountOpenedAt = accountOpenedAt
    payload.feeEvents = feeEvents
    payload.priceClaims = priceClaims
    payload.negotiableBills = negotiableBills
    payload.claimCases = claimCases
    payload.agentBudgets = agentBudgets
    payload.goals = goals
    payload.cardPurchases = cardPurchases
    payload.lastOrder = lastOrder
    payload.splits = splits
    payload.flaggedCharges = flaggedCharges
    payload.creditLimitMinor = creditLimitMinor
    payload.creditBalanceMinor = creditBalanceMinor
    payload.statementDay = statementDay
    payload.seededDesk = seededDesk
    payload.rules = rules
    payload.incomePlan = incomePlan
    payload.personaSlug = personaSlug
    do {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(payload)
      let tmp = path.appendingPathExtension("tmp")
      try data.write(to: tmp, options: .atomic)
      _ = try? FileManager.default.removeItem(at: path)
      try FileManager.default.moveItem(at: tmp, to: path)
      lastError = nil
    } catch {
      lastError = "Could not save the local directory: \(error.localizedDescription)"
    }
  }
}
