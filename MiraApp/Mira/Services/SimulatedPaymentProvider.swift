import Foundation

// MARK: - Scenarios

/// Lets the demo exercise branches that are not the happy path. The scenario is
/// shown in Demo controls so a viewer always knows which one is active.
enum PaymentScenario: String, Sendable, CaseIterable, Identifiable {
  case happyPath
  case slowProvider
  case timeout
  case providerFailure
  case duplicateEvent

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .happyPath: return "Settles normally"
    case .slowProvider: return "Provider is slow"
    case .timeout: return "Provider never answers"
    case .providerFailure: return "Provider reports failure"
    case .duplicateEvent: return "Duplicate provider events"
    }
  }

  var explanation: String {
    switch self {
    case .happyPath:
      return "Pending, then settled. Total falls by exactly the approved debit."
    case .slowProvider:
      return "Stays pending well past the quote window, then settles."
    case .timeout:
      return "Status becomes unknown. The payment is never marked settled and is reconciled first."
    case .providerFailure:
      return "Provider reports failed after pending. No money moves."
    case .duplicateEvent:
      return "The provider repeats its event. The ledger must not debit twice."
    }
  }
}

// MARK: - Provider

/// A synthetic local payment rail.
///
/// It is an actor so that concurrent submits, repeat events and reconciliation
/// reads cannot race each other. It cannot reach a real payment network: every
/// handle it accepts is a `sim-` handle.
actor SimulatedPaymentProvider: PaymentProvider {
  struct Config: Sendable {
    /// How long the provider stays pending before it reaches a definite state.
    var settleDelay: TimeInterval
    /// Whether the provider answers status queries at all.
    var answersStatusQueries: Bool
    init(settleDelay: TimeInterval = 2.6, answersStatusQueries: Bool = true) {
      self.settleDelay = settleDelay
      self.answersStatusQueries = answersStatusQueries
    }
  }

  private var config: Config
  private var scenario: PaymentScenario

  /// Submissions already accepted, keyed by the caller's idempotency key.
  /// A repeat submit returns the original reference instead of creating a
  /// second payment.
  private struct Accepted {
    let reference: String
    let submittedAt: Date
    let submission: PaymentSubmission
  }
  private var accepted: [String: Accepted] = [:]
  private var settledAt: [String: Date] = [:]
  private var failedReferences: Set<String> = []

  init(config: Config = Config(), scenario: PaymentScenario = .happyPath) {
    self.config = config
    self.scenario = scenario
  }

  func setScenario(_ scenario: PaymentScenario) {
    self.scenario = scenario
  }

  func currentScenario() -> PaymentScenario { scenario }

  func setConfig(_ config: Config) {
    self.config = config
  }

  // MARK: Payee resolution

  /// Resolves a handle to a recipient identity.
  ///
  /// Note how the returned names are the *provider's* answer: they are the
  /// authority, and the invoice label is only ever a hint.
  func resolvePayee(handle: String) async -> Payee.Verification {
    switch handle {
    case SyntheticDirectory.anaHandle:
      .resolved(legalName: SyntheticDirectory.anaLegalName)
    case SyntheticDirectory.mergedHandle:
      .resolved(legalName: SyntheticDirectory.mergedLegalName)
    case SyntheticDirectory.ambiguousHandle:
      .ambiguous(candidates: SyntheticDirectory.ambiguousCandidates)
    case SyntheticDirectory.unknownHandle:
      .unresolved(reason: "no such key at this institution")
    default:
      .unresolved(reason: "Mira resolves the keys in your address book")
    }
  }

  // MARK: Submit

  func submit(_ submission: PaymentSubmission) async -> ProviderOutcome {
    guard submission.recipientHandle.hasPrefix(Payee.syntheticMarker) else {
      return .failed(
        providerReference: nil,
        reason: "Refused: that key is not in your address book."
      )
    }

    if let existing = accepted[submission.idempotencyKey] {
      // Already have it. Report the existing state; never create a second one.
      return await outcome(for: existing.reference, now: Date())
    }

    let reference = Self.makeReference()
    accepted[submission.idempotencyKey] = Accepted(
      reference: reference,
      submittedAt: Date(),
      submission: submission
    )

    switch scenario {
    case .timeout:
      return .noResponse(note: "No answer from the provider within the timeout.")
    case .providerFailure:
      failedReferences.insert(reference)
      return .pending(providerReference: reference)
    case .happyPath, .slowProvider, .duplicateEvent:
      return .pending(providerReference: reference)
    }
  }

  // MARK: Status / reconciliation

  func reconcile(idempotencyKey: String) async -> ProviderOutcome {
    guard let existing = accepted[idempotencyKey] else {
      // The provider has no record, so nothing was accepted. Say exactly that,
      // rather than reporting a failure as though a payment had been attempted.
      return .failed(
        providerReference: nil,
        reason: "The provider has no record of this submission, so nothing was sent."
      )
    }
    guard config.answersStatusQueries else {
      return .noResponse(note: "Provider did not answer the reconciliation query.")
    }
    return await outcome(for: existing.reference, now: Date())
  }

  /// Replays the provider's own event for an already-accepted submission,
  /// which is how the duplicate-event branch is exercised in the demo.
  func replayEvent(idempotencyKey: String) async -> ProviderOutcome? {
    guard let existing = accepted[idempotencyKey] else { return nil }
    return await outcome(for: existing.reference, now: Date())
  }

  private func outcome(for reference: String, now: Date) async -> ProviderOutcome {
    guard let entry = accepted.values.first(where: { $0.reference == reference }) else {
      return .failed(providerReference: reference, reason: "Unknown provider reference.")
    }

    let state: PaymentScenario = scenario
    let delay = state == .slowProvider ? config.settleDelay * 3 : config.settleDelay

    if state == .timeout {
      return .noResponse(note: "No answer from the provider within the timeout.")
    }

    let elapsed = now.timeIntervalSince(entry.submittedAt)
    guard elapsed >= delay else {
      return .pending(providerReference: reference)
    }

    if failedReferences.contains(reference) {
      return .failed(
        providerReference: reference, reason: "The recipient's institution rejected the transfer.")
    }

    return .settled(
      providerReference: reference, settledAt: entry.submittedAt.addingTimeInterval(delay))
  }

  /// Reference format is deliberately opaque and prefixed, so it is obvious
  /// at a glance that it is not a real rail identifier.
  private static func makeReference() -> String {
    let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    let body = String((0..<10).map { _ in alphabet.randomElement()! })
    return "SIM-\(body)"
  }
}

// MARK: - Synthetic directory

/// The prototype's synthetic payee directory. These handles cannot submit a
/// real payment; they exist to exercise resolution, mismatch and ambiguity.
enum SyntheticDirectory {
  static let anaHandle = "sim-pix-ana-0192"
  static let anaInvoiceLabel = "Ana Moreira"
  static let anaLegalName = "Ana Beatriz Moreira da Silva"

  static let mergedHandle = "sim-pix-almeida-4471"
  static let mergedInvoiceLabel = "Almeida Consulting"
  static let mergedLegalName = "Almeida Consultoria e Serviços Ltda"

  static let ambiguousHandle = "sim-pix-js-0000"
  static let ambiguousCandidates = ["João Silva", "Joana Silva", "João da Silva"]

  static let unknownHandle = "sim-pix-unknown-9999"
}
