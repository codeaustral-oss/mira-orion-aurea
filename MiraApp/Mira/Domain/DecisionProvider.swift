import Foundation

// MARK: - Two independent mode indicators
//
// The brief requires these NEVER to be collapsed into one another.

/// The mode money movement itself runs in. Kept as domain state; never
/// rendered as a chip.
enum FinancialMode: String, Sendable, Codable {
  case simulated = "SIMULATED"
}

/// How the decision in front of you was actually produced.
enum DecisionMode: Equatable, Sendable, Codable {
  case jevLive(model: String)
  case llmFallback(model: String)
  case rulesOnly
  case demoFixtures
  /// The model was unreachable. Distinct from fallback, and never faked.
  case unavailable

  var label: String {
    switch self {
    case .jevLive(let model): return "Decision mode: JEV_LIVE · \(model)"
    case .llmFallback(let model): return "Decision mode: LLM_FALLBACK · \(model)"
    case .rulesOnly: return "Decision mode: RULES_ONLY"
    case .demoFixtures: return "Answered by: Mira (local)"
    case .unavailable: return "Decision mode: UNAVAILABLE"
    }
  }

  var shortLabel: String {
    switch self {
    case .jevLive: return "JEV_LIVE"
    case .llmFallback: return "LLM_FALLBACK"
    case .rulesOnly: return "RULES_ONLY"
    case .demoFixtures: return "Local"
    case .unavailable: return "UNAVAILABLE"
    }
  }

  /// True when a language model actually produced this answer.
  var isModelBacked: Bool {
    switch self {
    case .jevLive, .llmFallback: return true
    case .rulesOnly, .demoFixtures, .unavailable: return false
    }
  }
}

// MARK: - Intent

/// The closed routing vocabulary. `ambiguous` and `unsupported` always exist so
/// the system has an honest place to land.
enum Intent: String, Sendable, Codable, CaseIterable, Identifiable {
  case balance
  case receive
  case preparePayment = "prepare_payment"
  case budget
  case reserve
  case earnInformation = "earn_information"
  case cardHelp = "card_help"
  case support
  case ambiguous
  case unsupported

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .balance: return "Balance"
    case .receive: return "Receive"
    case .preparePayment: return "Prepare a payment"
    case .budget: return "Budget"
    case .reserve: return "Reserve"
    case .earnInformation: return "Earn information"
    case .cardHelp: return "Card help"
    case .support: return "Support"
    case .ambiguous: return "Ambiguous"
    case .unsupported: return "Unsupported"
    }
  }
}

// MARK: - Result

struct DecisionResult: Sendable {
  var intent: Intent
  /// Present for Choice and Score answers. Noul answers do not carry one.
  var confidence: Double?
  var probabilities: [String: Double]
  /// Noul: probability the request needs a clarifying question.
  var needsClarification: Double?
  /// Noul: signal that the content tried to instruct the assistant.
  ///
  /// This is a **signal, not a control**. It can inform copy and logging. It
  /// must never be the thing that grants or denies a permission.
  var embeddedInstructionSignal: Double?

  var mode: DecisionMode
  var resolvedModel: String?
  var latencyMs: Int
  var detail: String

  /// True when no workflow should be chosen, so the user gets explicit
  /// controls instead of a guess.
  var didReachNoFit: Bool {
    intent == .ambiguous
      || intent == .unsupported
      || confidence == nil
      || (confidence ?? 0) < DecisionPolicy.floor
  }

  /// Sorted probability distribution, for the "why" panel.
  var rankedProbabilities: [(intent: String, probability: Double)] {
    probabilities
      .map { (intent: $0.key, probability: $0.value) }
      .sorted { $0.probability > $1.probability }
  }

  static func unavailable(detail: String, latencyMs: Int = 0) -> DecisionResult {
    DecisionResult(
      intent: .ambiguous,
      confidence: nil,
      probabilities: [:],
      needsClarification: nil,
      embeddedInstructionSignal: nil,
      mode: .unavailable,
      resolvedModel: nil,
      latencyMs: latencyMs,
      detail: detail
    )
  }
}

/// Confidence thresholds. These are prototype starting values evaluated against
/// Mira-specific synthetic examples. They are not universal safety settings.
enum DecisionPolicy {
  /// Below this, do not use the label at all.
  static let floor: Double = 0.5
  /// Read-only routing is recoverable.
  static let readOnly: Double = 0.6
  /// Preparing an external financial action needs more.
  static let prepareAction: Double = 0.8
}

// MARK: - Adapter

/// The seam that lets Jev be replaced without changing product behaviour.
///
/// The mode travels on every `DecisionResult`, so the UI always reports how the
/// specific decision in front of it was produced rather than a global guess.
protocol DecisionProvider: Sendable {
  func classify(state: String, sessionId: String) async -> DecisionResult
}
