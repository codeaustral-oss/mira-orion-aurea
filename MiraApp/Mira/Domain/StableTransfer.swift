import CryptoKit
import Foundation

// MARK: - Addresses

/// A destination on a settlement network.
///
/// The prototype only accepts addresses carrying an explicit synthetic marker.
/// That is not decoration: it is the difference between a demo that cannot move
/// real value and one that merely promises not to.
struct ChainAddress: Hashable, Sendable, Codable {
  enum Network: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case ethereum
    case tron
    case base

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .ethereum: return "Ethereum"
      case .tron: return "Tron"
      case .base: return "Base"
      }
    }

    /// Rough settlement expectation shown to the user. Simulated.
    var typicalSettlement: String {
      switch self {
      case .ethereum, .base: return "about 2 minutes"
      case .tron: return "about 1 minute"
      }
    }
  }

  /// The only prefix this build will accept.
  static let syntheticPrefix = "0xSIM"

  let value: String
  let network: Network
  /// Optional human label the user set, so a raw address is not the only thing
  /// they ever see.
  let label: String?

  init(value: String, network: Network, label: String? = nil) {
    self.value = value
    self.network = network
    self.label = label
  }

  var isSynthetic: Bool { value.uppercased().hasPrefix(ChainAddress.syntheticPrefix) }

  /// Truncated for display: 0xSIM…9F2C
  var short: String {
    guard value.count > 12 else { return value }
    return "\(value.prefix(6))…\(value.suffix(4))"
  }

  var validationError: String? {
    if !isSynthetic {
      return
        "Mira sends to the addresses you have saved. Add one in Contacts."
    }
    if value.count < 12 {
      return "That address is too short."
    }
    return nil
  }
}

// MARK: - Transfer

/// A stablecoin send.
///
/// Deliberately the same shape as a local payment: an immutable draft, a
/// fingerprint, an explicit approval, a single idempotency key. Moving a token
/// should not be governed by looser rules than moving a real, so this reuses the
/// same consent model rather than inventing a second one.
struct ChainTransfer: Identifiable, Hashable, Sendable {
  let id: UUID
  let asset: Asset
  let to: ChainAddress
  let amount: Money
  let fee: Money
  let createdAt: Date
  var approval: PaymentApproval?
  var state: PaymentState
  var history: [StateTransition]

  init(
    id: UUID = UUID(),
    asset: Asset,
    to: ChainAddress,
    amount: Money,
    fee: Money,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.asset = asset
    self.to = to
    self.amount = amount
    self.fee = fee
    self.createdAt = createdAt
    self.approval = nil
    self.state = .draft
    self.history = [
      StateTransition(at: createdAt, from: .draft, to: .draft, note: "Transfer drafted")
    ]
  }

  var totalDebit: Money { amount + fee }

  var idempotencyKey: String { "transfer:\(id.uuidString)" }

  /// The exact terms a user is agreeing to.
  var fingerprint: String {
    let material = [
      asset.code, to.value, to.network.rawValue,
      "\(amount.minorUnits)", "\(fee.minorUnits)",
    ].joined(separator: "|")
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined()
  }

  var shortFingerprint: String { String(fingerprint.prefix(12)) }

  mutating func approve(consentId: String, at now: Date, userGesture: Bool) throws {
    guard case .draft = state else {
      throw PaymentTransitionError.invalidTransition(from: state.label, to: "Approved")
    }
    approval = PaymentApproval(
      draftFingerprint: fingerprint,
      quoteId: id,
      approvedAt: now,
      consentId: consentId,
      wasUserGesture: userGesture
    )
    try transition(to: .submitting, at: now, note: "Approved draft \(shortFingerprint)")
  }

  mutating func transition(to next: PaymentState, at now: Date, note: String? = nil) throws {
    let allowed: Bool
    switch (state, next) {
    case (.draft, .submitting): allowed = true
    case (.submitting, .pending): allowed = true
    case (.submitting, .settled): allowed = true
    case (.submitting, .statusUnknown): allowed = true
    case (.pending, .settled): allowed = true
    case (.pending, .failed): allowed = true
    case (.statusUnknown, .settled): allowed = true
    case (.statusUnknown, .failed): allowed = true
    default: allowed = false
    }
    guard allowed else {
      throw PaymentTransitionError.invalidTransition(from: state.label, to: next.label)
    }
    let previous = state
    state = next
    history.append(StateTransition(at: now, from: previous, to: next, note: note))
  }

  func confirmability(at now: Date, available: Money) -> Payment.Confirmability {
    if let error = to.validationError {
      return .blocked(.payeeNotResolved, error)
    }
    guard case .draft = state else {
      return .blocked(.duplicateSubmission, "This transfer has already been submitted.")
    }
    if totalDebit > available {
      return .blocked(
        .insufficientFunds(shortBy: totalDebit - available), "Not enough \(asset.code).")
    }
    return .ready
  }
}

// MARK: - Posting

extension Ledger {
  /// Posts a stablecoin send.
  ///
  /// Source decreases by the amount plus the fee; the fee is retained and the
  /// amount leaves to the external counterparty. Balances to zero in the token's
  /// own minor units.
  @discardableResult
  func postTransfer(_ transfer: ChainTransfer, at date: Date) throws -> Bool {
    let source = Ledger.accountId(for: transfer.asset)
    let feeAccount = "fees.\(transfer.asset.code.lowercased())"
    let external = "world.\(transfer.asset.code.lowercased())"

    return try post(
      JournalEntry(
        idempotencyKey: transfer.idempotencyKey,
        date: date,
        memo: "\(transfer.asset.code) to \(transfer.to.label ?? transfer.to.short)",
        references: EntryReferences(
          draftFingerprint: transfer.fingerprint,
          providerReference: transfer.state.providerReference,
          consentId: transfer.approval?.consentId
        ),
        postings: [
          Posting(
            accountId: source,
            amount: Money(minorUnits: -transfer.totalDebit.minorUnits, currency: transfer.asset)),
          Posting(accountId: feeAccount, amount: transfer.fee),
          Posting(accountId: external, amount: transfer.amount),
        ]
      )
    )
  }
}

// MARK: - Synthetic addresses

/// Addresses the prototype can resolve. Note the prefix: none of these can exist
/// on a real network, which is what makes them safe to demo.
enum AddressBook {
  static let studio = ChainAddress(
    value: "0xSIM4A7F2C91B8E3D6051AC", network: .base, label: "Studio Floripa")
  static let contractor = ChainAddress(
    value: "0xSIM9C1E5B7A2D4F80316BE", network: .ethereum, label: "Dev retainer")
  static let selfCustody = ChainAddress(
    value: "0xSIM2B8D4E6F1A930C57D2", network: .tron, label: "Personal wallet")
  static let unknown = ChainAddress(
    value: "0xSIM00000000000000000", network: .base, label: nil)

  static let all: [ChainAddress] = [studio, contractor, selfCustody]
}
