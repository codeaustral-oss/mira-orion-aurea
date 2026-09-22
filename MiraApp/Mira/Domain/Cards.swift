import Foundation

// MARK: - Cards

/// The reusable, typed cards the brief asks for.
///
/// The same card is produced whether the user arrived by tapping a button,
/// typing a sentence, or loading a sample — the arrival path must not change
/// the component, only which card is shown.
enum CardKind: String, Sendable, Codable {
  case balance
  case weekBudget
  case allocations
  case quote
  case paymentStatus
  case reserve
  case earnPreview
  case permission
  case clarification
  case activity
}

struct CardSpec: Identifiable, Hashable, Sendable {
  let id: String
  let label: String
  let value: String
  let mono: Bool
  let emphasis: SpecEmphasis
  let note: String?

  init(
    id: String = UUID().uuidString,
    label: String,
    value: String,
    mono: Bool = false,
    emphasis: SpecEmphasis = .normal,
    note: String? = nil
  ) {
    self.id = id
    self.label = label
    self.value = value
    self.mono = mono
    self.emphasis = emphasis
    self.note = note
  }
}

enum SpecEmphasis: String, Sendable {
  case normal
  case strong
  case muted
}

enum CardActionRole: String, Sendable {
  case primary
  case secondary
  case ghost
  case destructive
}

struct CardAction: Identifiable, Hashable, Sendable {
  enum Act: Hashable, Sendable {
    case openPlan
    case openPay
    case openReserve
    case openEarn
    case openActivity
    case openControl
    case approvePayment
    case confirmPayment
    case refreshQuote
    case reconcile
    case clarify(String)
    case dismiss
  }

  let id: String
  let title: String
  let role: CardActionRole
  let act: Act
  let isEnabled: Bool

  init(
    id: String = UUID().uuidString,
    title: String,
    role: CardActionRole = .secondary,
    act: Act,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.title = title
    self.role = role
    self.act = act
    self.isEnabled = isEnabled
  }
}

/// A card is data. It carries the canonical numbers and never a free-form
/// payload a model could have written.
struct ActionCard: Identifiable, Sendable {
  let id: UUID
  let kind: CardKind
  let title: String
  let subtitle: String?
  let specs: [CardSpec]
  let footnote: String?
  let actions: [CardAction]
  /// How the decision that produced this card was actually made.
  let mode: DecisionMode
  /// Set when this card must not be acted on until the user fixes something.
  let blockReason: String?

  init(
    id: UUID = UUID(),
    kind: CardKind,
    title: String,
    subtitle: String? = nil,
    specs: [CardSpec] = [],
    footnote: String? = nil,
    actions: [CardAction] = [],
    mode: DecisionMode,
    blockReason: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.specs = specs
    self.footnote = footnote
    self.actions = actions
    self.mode = mode
    self.blockReason = blockReason
  }
}

// MARK: - Explanation

/// A composed answer.
///
/// The prose explains a card. The numbers in it are read from computed state
/// and cited, never produced by a language model. That is the whole point of
/// Journey C: "Mira retrieves the computed amount ... it does not generate the
/// amount from language-model reasoning."
struct Explanation: Sendable {
  let headline: String
  let body: String
  /// Where each figure came from. Shown under the answer.
  let citations: [String]
  let cards: [ActionCard]
  let mode: DecisionMode
  let decision: DecisionResult

  init(
    headline: String,
    body: String,
    citations: [String],
    cards: [ActionCard],
    mode: DecisionMode,
    decision: DecisionResult
  ) {
    self.headline = headline
    self.body = body
    self.citations = citations
    self.cards = cards
    self.mode = mode
    self.decision = decision
  }
}
