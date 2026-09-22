import Foundation
import Observation

// MARK: - Accounts

enum AccountKind: String, Hashable, Sendable, Codable {
  /// Spendable, cleared USD the user can actually allocate.
  case usdCleared
  /// USD that has been signalled but not cleared. NEVER spendable.
  case usdPending
  /// Cleared BRL held for local spending.
  case brlCleared
  /// Technical account that absorbs the base side of an FX conversion so the
  /// book balances per currency. Not user-facing.
  case fxClearing
  /// Technical account for fees. Not user-facing.
  case feeIncome
  /// Counterparty account representing money entering or leaving the
  /// prototype. Keeping it explicit is what lets inflows balance.
  case external
}

struct LedgerAccount: Identifiable, Hashable, Sendable, Codable {
  let id: String
  let name: String
  let kind: AccountKind
  let currency: Asset

  init(id: String, name: String, kind: AccountKind, currency: Asset) {
    self.id = id
    self.name = name
    self.kind = kind
    self.currency = currency
  }

  /// True when funds in this account are part of what the user may allocate.
  var isSpendable: Bool { kind == .usdCleared }
  var isUserFacing: Bool { kind != .fxClearing && kind != .feeIncome && kind != .external }
}

// MARK: - Postings

/// A single signed movement against one account.
struct Posting: Hashable, Sendable, Codable {
  let accountId: String
  let amount: Money

  init(accountId: String, amount: Money) {
    self.accountId = accountId
    self.amount = amount
  }
}

enum LedgerError: Error, Equatable {
  case unbalanced(currency: String, residualMinorUnits: Int64)
  case emptyEntry
  case unknownAccount(String)
  case currencyMismatch(accountId: String, expected: String, got: String)
  case noAccountsProvided
}

// MARK: - Journal

/// A balanced, append-only journal.
///
/// Every entry must sum to zero in **each** currency it touches. FX movements
/// are represented with an explicit clearing posting rather than an implicit
/// rate, so a conversion can always be audited.
struct JournalEntry: Identifiable, Hashable, Sendable, Codable {
  let id: UUID
  /// Caller-supplied key. Replaying the same key is ignored, which is how
  /// duplicate submits and repeated provider events stay single-debit.
  let idempotencyKey: String
  let date: Date
  let memo: String
  /// What the user asked for, what draft was approved, what was submitted.
  let references: EntryReferences
  let postings: [Posting]

  init(
    id: UUID = UUID(),
    idempotencyKey: String,
    date: Date,
    memo: String,
    references: EntryReferences = .init(),
    postings: [Posting]
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.date = date
    self.memo = memo
    self.references = references
    self.postings = postings
  }
}

/// Traceability for a receipt: a receipt must record what was requested, the
/// exact draft approved, what the system submitted, and what the provider
/// reported.
struct EntryReferences: Hashable, Sendable, Codable {
  var instruction: String?
  var draftFingerprint: String?
  var providerReference: String?
  var consentId: String?

  init(
    instruction: String? = nil,
    draftFingerprint: String? = nil,
    providerReference: String? = nil,
    consentId: String? = nil
  ) {
    self.instruction = instruction
    self.draftFingerprint = draftFingerprint
    self.providerReference = providerReference
    self.consentId = consentId
  }
}

@Observable
final class Ledger {
  private(set) var accounts: [String: LedgerAccount]
  private(set) var entries: [JournalEntry] = []
  private var appliedIdempotencyKeys: Set<String> = []

  init(accounts: [LedgerAccount]) throws {
    guard !accounts.isEmpty else { throw LedgerError.noAccountsProvided }
    self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
  }

  /// Appends an entry after validating that it balances per currency and that
  /// every posting targets a known account with a matching currency.
  ///
  /// Returns `false` when the entry was already applied (same idempotency
  /// key), so a repeated provider event cannot move money twice.
  @discardableResult
  func post(_ entry: JournalEntry) throws -> Bool {
    guard !entry.postings.isEmpty else { throw LedgerError.emptyEntry }

    if appliedIdempotencyKeys.contains(entry.idempotencyKey) {
      return false
    }

    var residuals: [String: Int64] = [:]
    for posting in entry.postings {
      guard let account = accounts[posting.accountId] else {
        throw LedgerError.unknownAccount(posting.accountId)
      }
      guard account.currency == posting.amount.currency else {
        throw LedgerError.currencyMismatch(
          accountId: posting.accountId,
          expected: account.currency.code,
          got: posting.amount.currency.code
        )
      }
      residuals[account.currency.code, default: 0] += posting.amount.minorUnits
    }

    for (code, residual) in residuals where residual != 0 {
      throw LedgerError.unbalanced(currency: code, residualMinorUnits: residual)
    }

    appliedIdempotencyKeys.insert(entry.idempotencyKey)
    entries.append(entry)
    return true
  }

  /// Balance of one account, derived from the journal rather than stored
  /// separately. The journal is the single source of truth.
  func balance(of accountId: String) -> Money {
    guard let account = accounts[accountId] else { return Money.zero(.usd) }
    let total =
      entries
      .flatMap(\.postings)
      .filter { $0.accountId == accountId }
      .reduce(Int64(0)) { $0 + $1.amount.minorUnits }
    return Money(minorUnits: total, currency: account.currency)
  }

  /// Cleared, spendable USD. Pending deposits are excluded by construction:
  /// they live in a different account.
  var clearedSpendableUSD: Money {
    balance(of: "usd.cleared")
  }

  var pendingUSD: Money {
    balance(of: "usd.pending")
  }

  var brlBalance: Money {
    balance(of: "brl.cleared")
  }

  func entries(for accountId: String) -> [JournalEntry] {
    entries.filter { entry in entry.postings.contains { $0.accountId == accountId } }
  }

  /// Newest first, for the activity list.
  var newestFirst: [JournalEntry] {
    entries.sorted { $0.date > $1.date }
  }
}

// MARK: - Standard chart of accounts

extension Ledger {
  static func miraPrototype() throws -> Ledger {
    var accounts: [LedgerAccount] = [
      LedgerAccount(id: "usd.cleared", name: "US Dollar", kind: .usdCleared, currency: .usd),
      LedgerAccount(id: "usd.pending", name: "USD pending", kind: .usdPending, currency: .usd),
      LedgerAccount(id: "brl.cleared", name: "Brazilian Real", kind: .brlCleared, currency: .brl),
      LedgerAccount(id: "eur.cleared", name: "Euro", kind: .brlCleared, currency: .eur),
      LedgerAccount(id: "fx.clearing", name: "FX clearing", kind: .fxClearing, currency: .usd),
      LedgerAccount(
        id: "fx.clearing.brl", name: "FX clearing BRL", kind: .fxClearing, currency: .brl),
      LedgerAccount(
        id: "fx.clearing.eur", name: "FX clearing EUR", kind: .fxClearing, currency: .eur),
      LedgerAccount(id: "world.usd", name: "External USD", kind: .external, currency: .usd),
      LedgerAccount(id: "world.brl", name: "External BRL", kind: .external, currency: .brl),
      LedgerAccount(id: "world.eur", name: "External EUR", kind: .external, currency: .eur),
    ]

    // Each stablecoin gets a wallet, a clearing account and a counterparty, all
    // at that token's own precision.
    for asset in Asset.stablecoins {
      let key = asset.code.lowercased()
      accounts.append(
        LedgerAccount(id: "\(key).wallet", name: asset.name, kind: .brlCleared, currency: asset))
      accounts.append(
        LedgerAccount(
          id: "fx.clearing.\(key)", name: "FX clearing \(asset.code)", kind: .fxClearing,
          currency: asset))
      accounts.append(
        LedgerAccount(
          id: "world.\(key)", name: "External \(asset.code)", kind: .external, currency: asset))
    }

    // A fee account per asset, so a fee can be taken in whatever asset the
    // movement was denominated in and the book still balances per asset.
    for asset in Asset.all {
      accounts.append(
        LedgerAccount(
          id: "fees.\(asset.code.lowercased())", name: "Fees \(asset.code)", kind: .feeIncome,
          currency: asset))
    }

    return try Ledger(accounts: accounts)
  }

  /// Where an asset's spendable balance lives.
  static func accountId(for asset: Asset) -> String {
    asset.kind == .stablecoin
      ? "\(asset.code.lowercased()).wallet"
      : "\(asset.code.lowercased()).cleared"
  }

  /// The spendable balance of any asset the user holds.
  func balance(ofAsset asset: Asset) -> Money {
    balance(of: Ledger.accountId(for: asset))
  }

  /// Every asset the prototype holds, in a stable display order.
  func holdings() -> [(asset: Asset, amount: Money)] {
    Asset.all.map { ($0, balance(ofAsset: $0)) }
  }
}
