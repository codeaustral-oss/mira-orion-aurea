import Foundation

// MARK: - Specialist
//
// Mira is a coordinator, not a generic assistant. Every conversation is routed to
// one of six specialists per brand. This file is the app's own copy of the
// roster: the server owns the `instructions` that reach the model, while the app
// owns what is displayed. They are kept in step by the shared `id`.
//
// The avatar asset names are wired now (`agent-aurea-planner`, and so on) so the
// parent can drop the generated images into the catalog with no code change.
// Until then, and whenever an image is missing, the specialist renders as its
// SF Symbol. That fallback is a real fallback, not a placeholder to ship.

struct AgentSpecialist: Identifiable, Hashable, Sendable {
  let id: String
  let brand: BrandKind
  let name: String
  let role: String
  let personality: String
  /// The SF Symbol fallback.
  let symbol: String
  /// The catalog name the generated avatar will use.
  let assetName: String

  var displayName: String { name }
}

enum AgentRoster {
  static let aurea: [AgentSpecialist] = [
    AgentSpecialist(
      id: "planner", brand: .aurea, name: "Planner", role: "Plans and priorities",
      personality: "Unhurried, structured, allergic to loose ends. Turns a vague month into a sequence of decisions.",
      symbol: "calendar.badge.clock", assetName: "agent-aurea-planner"),
    AgentSpecialist(
      id: "accountant", brand: .aurea, name: "Accountant", role: "Numbers and budget",
      personality: "Precise and literal. Quotes the ledger back exactly, and says when a figure is not there.",
      symbol: "number.square", assetName: "agent-aurea-accountant"),
    AgentSpecialist(
      id: "treasurer", brand: .aurea, name: "Treasurer", role: "Money movement and reserves",
      personality: "Cautious with movement, protective of reserves. Wants the exact amount and destination before anything moves.",
      symbol: "banknote", assetName: "agent-aurea-treasurer"),
    AgentSpecialist(
      id: "concierge", brand: .aurea, name: "Concierge", role: "Tasks, requests and arrangements",
      personality: "Helpful and concrete. Breaks a wish into requirements, and is honest when a provider is not connected.",
      symbol: "bell", assetName: "agent-aurea-concierge"),
    AgentSpecialist(
      id: "negotiator", brand: .aurea, name: "Negotiator", role: "Deals, rates and providers",
      personality: "Composed under pressure. Talks in terms and trade-offs, never in pressure or urgency.",
      symbol: "handshake", assetName: "agent-aurea-negotiator"),
    AgentSpecialist(
      id: "guardian", brand: .aurea, name: "Guardian", role: "Safety, cards and permissions",
      personality: "Watchful and calm. Says plainly what is protected and what is not, without alarm.",
      symbol: "checkmark.shield", assetName: "agent-aurea-guardian"),
  ]

  static let orion: [AgentSpecialist] = [
    AgentSpecialist(
      id: "navigator", brand: .orion, name: "Navigator", role: "Direction and sequence",
      personality: "Maps the whole route before the first step. Comfortable saying the path is not known yet.",
      symbol: "location.north.line", assetName: "agent-orion-navigator"),
    AgentSpecialist(
      id: "analyst", brand: .orion, name: "Analyst", role: "Numbers and signals",
      personality: "Reads the pattern, not the mood. States the figure, the source and the uncertainty.",
      symbol: "chart.xyaxis.line", assetName: "agent-orion-analyst"),
    AgentSpecialist(
      id: "quartermaster", brand: .orion, name: "Quartermaster", role: "Movement and holdings",
      personality: "Keeps stock of everything. Nothing leaves without an exact count and a named destination.",
      symbol: "shippingbox", assetName: "agent-orion-quartermaster"),
    AgentSpecialist(
      id: "scout", brand: .orion, name: "Scout", role: "Reconnaissance and requests",
      personality: "Fast to check, slow to promise. Reports what it actually found, including nothing.",
      symbol: "binoculars", assetName: "agent-orion-scout"),
    AgentSpecialist(
      id: "broker", brand: .orion, name: "Broker", role: "Rates and counterparties",
      personality: "Measured and transactional. Speaks in terms and costs, never in guarantees.",
      symbol: "arrow.left.arrow.right.square", assetName: "agent-orion-broker"),
    AgentSpecialist(
      id: "sentinel", brand: .orion, name: "Sentinel", role: "Safety and access",
      personality: "Quiet perimeter. States the state of the locks and never dramatizes them.",
      symbol: "shield.lefthalf.filled", assetName: "agent-orion-sentinel"),
  ]

  static func forBrand(_ brand: BrandKind) -> [AgentSpecialist] {
    brand == .aurea ? aurea : orion
  }

  static func agent(brand: BrandKind, id: String?) -> AgentSpecialist {
    let list = forBrand(brand)
    if let id, let match = list.first(where: { $0.id == id }) { return match }
    return coordinator(brand)
  }

  /// The brand's default specialist. Not a seventh agent: it is the front desk
  /// that answers before routing, wearing the roster's first name.
  static func coordinator(_ brand: BrandKind) -> AgentSpecialist {
    brand == .aurea ? aurea[0] : orion[0]
  }
}

// MARK: - Typed action
//
// The server decides one typed action per turn. The model never chooses the
// recipient, the amount or the action: it only writes prose about a decision
// deterministic code already made.

struct AgentAction: Sendable, Equatable {
  enum Kind: String, Sendable, Codable, CaseIterable {
    case askTransferDetails = "ask_transfer_details"
    case proposeTransfer = "propose_transfer"
    case showBudget = "show_budget"
    case proposeBudgetUpdate = "propose_budget_update"
    case showBalance = "show_balance"
    case openCardControls = "open_card_controls"
    case openReceive = "open_receive"
    case requirementsFlow = "requirements_flow"
    /// A research or comparison task the server accepted and will run in the
    /// background. The app polls the task endpoint; the turn shows its progress.
    case agentTask = "agent_task"
    case reply
    /// Local only: a receipt for a transfer this app just settled.
    case transferReceipt = "transfer_receipt"
  }

  let kind: Kind
  var to: String?
  var from: String?
  var assetCode: String?
  var amountMinor: Int64?
  var missing: [String] = []
  var topic: String?
  var providerConnected: Bool?
  var requirements: [String] = []
  var focus: String?
  /// The recipients this app can actually address. Empty when the action is not
  /// a transfer request. Used so the UI never has to invent a payee.
  var knownRecipients: [String] = []
  /// Agent-task fields. `taskId` is the handle the app polls; `taskTitle` and
  /// `taskStatus` are the acknowledgement the server sent with the turn.
  var taskId: String?
  var taskTitle: String?
  var taskStatus: String?
  // Receipt fields, filled in by the app after a settled transfer.
  var transferId: String?
  var receiptLine: String?
  var isSimulated: Bool = false

  var asset: Asset? {
    guard let assetCode else { return nil }
    return Asset.all.first { $0.code == assetCode }
  }

  var amount: Money? {
    guard let asset, let amountMinor else { return nil }
    return Money(minorUnits: amountMinor, currency: asset)
  }

  static let reply = AgentAction(kind: .reply)
}

// MARK: - Codable
//
// Hand-written so a turn can be persisted and re-read, and so a field the server
// omits decodes to its default instead of failing the whole transcript.

extension AgentAction: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, to, from, assetCode, amountMinor, missing, topic, providerConnected
    case requirements, focus, knownRecipients, transferId, receiptLine, isSimulated
    case taskId, taskTitle, taskStatus
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = (try? c.decode(String.self, forKey: .kind)) ?? Kind.reply.rawValue
    kind = Kind(rawValue: raw) ?? .reply
    to = try? c.decode(String.self, forKey: .to)
    from = try? c.decode(String.self, forKey: .from)
    assetCode = try? c.decode(String.self, forKey: .assetCode)
    amountMinor = try? c.decode(Int64.self, forKey: .amountMinor)
    missing = (try? c.decode([String].self, forKey: .missing)) ?? []
    topic = try? c.decode(String.self, forKey: .topic)
    providerConnected = try? c.decode(Bool.self, forKey: .providerConnected)
    requirements = (try? c.decode([String].self, forKey: .requirements)) ?? []
    focus = try? c.decode(String.self, forKey: .focus)
    knownRecipients = (try? c.decode([String].self, forKey: .knownRecipients)) ?? []
    transferId = try? c.decode(String.self, forKey: .transferId)
    receiptLine = try? c.decode(String.self, forKey: .receiptLine)
    isSimulated = (try? c.decode(Bool.self, forKey: .isSimulated)) ?? false
    taskId = try? c.decode(String.self, forKey: .taskId)
    taskTitle = try? c.decode(String.self, forKey: .taskTitle)
    taskStatus = try? c.decode(String.self, forKey: .taskStatus)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind.rawValue, forKey: .kind)
    try c.encodeIfPresent(to, forKey: .to)
    try c.encodeIfPresent(from, forKey: .from)
    try c.encodeIfPresent(assetCode, forKey: .assetCode)
    try c.encodeIfPresent(amountMinor, forKey: .amountMinor)
    if !missing.isEmpty { try c.encode(missing, forKey: .missing) }
    try c.encodeIfPresent(topic, forKey: .topic)
    try c.encodeIfPresent(providerConnected, forKey: .providerConnected)
    if !requirements.isEmpty { try c.encode(requirements, forKey: .requirements) }
    try c.encodeIfPresent(focus, forKey: .focus)
    if !knownRecipients.isEmpty { try c.encode(knownRecipients, forKey: .knownRecipients) }
    try c.encodeIfPresent(transferId, forKey: .transferId)
    try c.encodeIfPresent(receiptLine, forKey: .receiptLine)
    if isSimulated { try c.encode(isSimulated, forKey: .isSimulated) }
    try c.encodeIfPresent(taskId, forKey: .taskId)
    try c.encodeIfPresent(taskTitle, forKey: .taskTitle)
    try c.encodeIfPresent(taskStatus, forKey: .taskStatus)
  }
}

// MARK: - Orchestration result

/// One routed turn: what Jev decided, which specialist answered, and what the
/// app should render next.
struct OrchestrationResult: Sendable {
  var intent: Intent
  var decisionMode: DecisionMode
  var specialist: AgentSpecialist
  var action: AgentAction
  var say: String
  /// "muse" when a model wrote the prose, "unavailable" when it did not.
  var source: String
  var model: String
  var latencyMs: Int
  var confidence: Double?
  var embeddedInstructionSignal: Double?
  /// The Jev decision that produced this turn. Kept separate from the prose
  /// latency so a deterministic fast reply never hides the real decision.
  var decisionModel: String? = nil
  var decisionLatencyMs: Int = 0

  var isModelBacked: Bool { source == "muse" }
  /// True when the reply was composed by deterministic code, not a model.
  var isFastPath: Bool { source == "deterministic" }
}
