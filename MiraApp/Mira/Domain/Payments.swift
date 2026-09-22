import CryptoKit
import Foundation

// MARK: - Payee

/// A payment recipient.
///
/// Two identities matter and they are not the same thing:
///  - `label` is what the instruction said (an invoice can print anything).
///  - `verification` is what the provider actually returned.
/// The brief requires showing the provider-returned identity, and refusing to
/// guess when the two disagree.
struct Payee: Identifiable, Hashable, Sendable, Codable {
  enum Verification: Hashable, Sendable, Codable {
    /// The provider resolved the handle to a real, named recipient.
    case resolved(legalName: String)
    /// The provider could not confirm the recipient.
    case unresolved(reason: String)
    /// The handle matched more than one candidate. Never guess.
    case ambiguous(candidates: [String])
  }

  let id: String
  /// The label printed on the instruction. Untrusted, display only.
  let label: String
  /// A synthetic key that cannot reach a real payment rail.
  let handle: String
  let institution: String
  let verification: Verification

  init(
    id: String,
    label: String,
    handle: String,
    institution: String,
    verification: Verification
  ) {
    self.id = id
    self.label = label
    self.handle = handle
    self.institution = institution
    self.verification = verification
  }

  /// The name to show as the recipient. Comes from the provider, never from
  /// the instruction text.
  var resolvedName: String? {
    if case .resolved(let name) = verification { return name }
    return nil
  }

  /// True when this payee is safe to prepare a payment against.
  var isResolvable: Bool {
    if case .resolved = verification { return true }
    return false
  }

  /// The label the instruction used, when it differs from the resolved name.
  var mismatchNote: String? {
    guard let resolved = resolvedName, resolved.caseInsensitiveCompare(label) != .orderedSame else {
      return nil
    }
    return "The instruction said “\(label)”. The provider returned “\(resolved)”."
  }

  /// Explanation for an unresolved or ambiguous recipient.
  var blockReason: String? {
    switch verification {
    case .resolved:
      return nil
    case .unresolved(let reason):
      return "The provider could not confirm this recipient: \(reason)"
    case .ambiguous(let candidates):
      return
        "This key matches more than one recipient (\(candidates.joined(separator: ", "))). Correct it before paying."
    }
  }

  /// A synthetic handle always carries this marker so a demo can never be
  /// mistaken for a live rail destination.
  static let syntheticMarker = "sim-"
}

// MARK: - Draft

/// An immutable payment draft. Approving a draft binds approval to a
/// fingerprint of its material fields, so any later change invalidates consent.
struct PaymentDraft: Identifiable, Hashable, Sendable, Codable {
  let id: UUID
  let payee: Payee
  let quote: FXQuote
  /// The original instruction, preserved verbatim for the receipt.
  let instruction: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    payee: Payee,
    quote: FXQuote,
    instruction: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.payee = payee
    self.quote = quote
    self.instruction = instruction
    self.createdAt = createdAt
  }

  /// The material fields: everything a user would consider "what I agreed to".
  private var materialFields: String {
    [
      payee.id,
      payee.handle,
      payee.resolvedName ?? "unresolved",
      quote.id.uuidString,
      quote.sourceAccountId,
      quote.direction.base.code,
      quote.direction.quote.code,
      "\(quote.rate)",
      "\(quote.recipientAmount.currency.code):\(quote.recipientAmount.minorUnits)",
      "\(quote.conversionDebit.currency.code):\(quote.conversionDebit.minorUnits)",
      "\(quote.fee.currency.code):\(quote.fee.minorUnits)",
      quote.expiresAt.timeIntervalSince1970.description,
    ].joined(separator: "|")
  }

  /// Stable digest of the material fields.
  var fingerprint: String {
    let digest = SHA256.hash(data: Data(materialFields.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined()
  }

  /// Short form for display on the receipt and consent log.
  var shortFingerprint: String {
    String(fingerprint.prefix(12))
  }
}

/// Explicit, recorded consent for one exact draft.
struct PaymentApproval: Hashable, Sendable, Codable {
  let draftFingerprint: String
  let quoteId: UUID
  let approvedAt: Date
  let consentId: String
  /// True only when the approval came from a real, verified user gesture.
  /// A decorative animation must never set this.
  let wasUserGesture: Bool

  init(
    draftFingerprint: String,
    quoteId: UUID,
    approvedAt: Date,
    consentId: String,
    wasUserGesture: Bool
  ) {
    self.draftFingerprint = draftFingerprint
    self.quoteId = quoteId
    self.approvedAt = approvedAt
    self.consentId = consentId
    self.wasUserGesture = wasUserGesture
  }
}

// MARK: - State

/// Payment lifecycle.
///
/// A provider timeout is neither a failure nor a success; it is `statusUnknown`
/// and must be reconciled before any retry.
enum PaymentState: Hashable, Sendable, Codable {
  case draft
  case awaitingApproval
  case submitting
  case pending(providerReference: String)
  case settled(providerReference: String, settledAt: Date)
  case failed(providerReference: String?, reason: String)
  case statusUnknown(providerReference: String?, note: String)

  var isTerminal: Bool {
    switch self {
    case .settled, .failed: return true
    default: return false
    }
  }

  var isSettled: Bool {
    if case .settled = self { return true }
    return false
  }

  var isUnknown: Bool {
    if case .statusUnknown = self { return true }
    return false
  }

  /// Money has moved (or may have moved) at the provider.
  var isInFlightOrBeyond: Bool {
    switch self {
    case .submitting, .pending, .settled, .statusUnknown: return true
    case .draft, .awaitingApproval, .failed: return false
    }
  }

  var providerReference: String? {
    switch self {
    case .pending(let ref): return ref
    case .settled(let ref, _): return ref
    case .failed(let ref, _): return ref
    case .statusUnknown(let ref, _): return ref
    default: return nil
    }
  }

  var label: String {
    switch self {
    case .draft: return "Draft"
    case .awaitingApproval: return "Awaiting your approval"
    case .submitting: return "Submitting"
    case .pending: return "Pending at provider"
    case .settled: return "Settled"
    case .failed: return "Failed"
    case .statusUnknown: return "Status unknown"
    }
  }

  /// Status must not depend on colour alone, so every state carries a
  /// distinct glyph as well.
  var glyph: String {
    switch self {
    case .draft: return "doc.text"
    case .awaitingApproval: return "checkmark.seal"
    case .submitting: return "arrow.up.forward"
    case .pending: return "clock"
    case .settled: return "checkmark.circle"
    case .failed: return "xmark.octagon"
    case .statusUnknown: return "questionmark.diamond"
    }
  }
}

enum PaymentTransitionError: Error, Equatable {
  case quoteExpired
  case approvalMissing
  case approvalStale
  case invalidTransition(from: String, to: String)
  case duplicateSubmission
  case payeeNotResolved
  case insufficientFunds(shortBy: Money)

  var headline: String {
    switch self {
    case .quoteExpired: return "This quote expired"
    case .approvalMissing: return "Approval required"
    case .approvalStale: return "The details changed"
    case .invalidTransition: return "That step is not available"
    case .duplicateSubmission: return "Already submitted"
    case .payeeNotResolved: return "Recipient not verified"
    case .insufficientFunds: return "Not enough available funds"
    }
  }
}

struct StateTransition: Identifiable, Hashable, Sendable {
  let id: UUID
  let at: Date
  let from: PaymentState
  let to: PaymentState
  let note: String?

  init(id: UUID = UUID(), at: Date, from: PaymentState, to: PaymentState, note: String? = nil) {
    self.id = id
    self.at = at
    self.from = from
    self.to = to
    self.note = note
  }
}

// MARK: - Payment aggregate

/// The full payment record: draft, consent, current state and history.
struct Payment: Identifiable, Hashable, Sendable {
  let id: UUID
  var draft: PaymentDraft
  var approval: PaymentApproval?
  var state: PaymentState
  var history: [StateTransition]
  /// Set once the provider has been given this payment, so a duplicate submit
  /// can never allocate a second provider reference.
  var idempotencyKey: String

  init(draft: PaymentDraft, now: Date = Date()) {
    self.id = draft.id
    self.draft = draft
    self.approval = nil
    self.state = .draft
    self.history = [StateTransition(at: now, from: .draft, to: .draft, note: "Draft created")]
    self.idempotencyKey = "payment:\(draft.id.uuidString)"
  }

  mutating func transition(to next: PaymentState, at now: Date, note: String? = nil) throws {
    guard transitionIsAllowed(from: state, to: next) else {
      throw PaymentTransitionError.invalidTransition(from: state.label, to: next.label)
    }
    let previous = state
    state = next
    history.append(StateTransition(at: now, from: previous, to: next, note: note))
  }

  private func transitionIsAllowed(from: PaymentState, to: PaymentState) -> Bool {
    switch (from, to) {
    case (.draft, .awaitingApproval): return true
    case (.awaitingApproval, .draft): return true
    case (.awaitingApproval, .submitting): return true
    case (.submitting, .pending): return true
    case (.submitting, .failed): return true
    case (.submitting, .statusUnknown): return true
    case (.pending, .settled): return true
    case (.pending, .failed): return true
    case (.pending, .statusUnknown): return true
    // Reconciliation moves an unknown status to a definite outcome.
    case (.statusUnknown, .settled): return true
    case (.statusUnknown, .failed): return true
    case (.statusUnknown, .pending): return true
    default: return false
    }
  }

  /// Records approval, but only for the exact draft currently held.
  mutating func approve(consentId: String, at now: Date, userGesture: Bool) throws {
    guard case .draft = state else {
      throw PaymentTransitionError.invalidTransition(
        from: state.label, to: "Awaiting your approval")
    }
    approval = PaymentApproval(
      draftFingerprint: draft.fingerprint,
      quoteId: draft.quote.id,
      approvedAt: now,
      consentId: consentId,
      wasUserGesture: userGesture
    )
    try transition(
      to: .awaitingApproval, at: now, note: "User approved draft \(draft.shortFingerprint)")
  }

  /// Whether confirmation is currently permitted, and why not if it is not.
  func confirmability(at now: Date, availableFunds: Money) -> Confirmability {
    if state.isInFlightOrBeyond {
      return .blocked(.duplicateSubmission, "This payment has already been submitted.")
    }
    guard draft.payee.isResolvable else {
      return .blocked(
        .payeeNotResolved, draft.payee.blockReason ?? "The recipient is not verified.")
    }
    guard case .awaitingApproval = state else {
      return .blocked(.approvalMissing, "Approve this payment before confirming it.")
    }
    guard let approval else {
      return .blocked(.approvalMissing, "Approve this payment before confirming it.")
    }
    guard approval.draftFingerprint == draft.fingerprint, approval.quoteId == draft.quote.id else {
      return .blocked(
        .approvalStale, "The payment details changed after approval. Review and approve again.")
    }
    if draft.quote.isExpired(at: now) {
      return .blocked(.quoteExpired, "This quote expired. Request a new quote to continue.")
    }
    if draft.quote.totalDebit > availableFunds {
      return .blocked(
        .insufficientFunds(shortBy: draft.quote.totalDebit - availableFunds),
        "Not enough available funds at the source."
      )
    }
    return .ready
  }

  enum Confirmability: Equatable, Sendable {
    case ready
    case blocked(PaymentTransitionError, String)

    var isReady: Bool { self == .ready }

    var blockReason: String? {
      if case .blocked(_, let reason) = self { return reason }
      return nil
    }
  }
}

// MARK: - Provider boundary

/// What the system submits, after approval.
struct PaymentSubmission: Hashable, Sendable, Codable {
  /// Deterministic reference so the provider can deduplicate.
  let idempotencyKey: String
  let draftFingerprint: String
  let recipientHandle: String
  let recipientName: String
  let recipientAmount: Money
  let debitAmount: Money
  let fee: Money
  let quoteId: UUID
  let consentId: String
}

/// What the provider reports back.
enum ProviderOutcome: Hashable, Sendable {
  case pending(providerReference: String)
  case settled(providerReference: String, settledAt: Date)
  case failed(providerReference: String?, reason: String)
  /// No answer in time. This is explicitly NOT a failure.
  case noResponse(note: String)

  var isDefinite: Bool {
    switch self {
    case .pending, .settled, .failed: return true
    case .noResponse: return false
    }
  }
}

/// A local payment rail. The demo implementation is synthetic and cannot reach
/// a real payment network.
protocol PaymentProvider: Sendable {
  func submit(_ submission: PaymentSubmission) async -> ProviderOutcome
  /// Used to reconcile an unknown status before any retry.
  ///
  /// Keyed on the *caller's* idempotency key, not a provider reference: after a
  /// timeout the app may never have received a reference, and the idempotency
  /// key is precisely the thing that survives that gap.
  func reconcile(idempotencyKey: String) async -> ProviderOutcome
  /// Provider-resolved recipient identity.
  func resolvePayee(handle: String) async -> Payee.Verification
}
