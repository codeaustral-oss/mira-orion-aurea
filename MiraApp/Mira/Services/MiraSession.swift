import Foundation
import Observation
import SwiftUI

// MARK: - Supporting records

/// One turn in the Mira conversation. A Mira turn always carries the structured
/// cards it produced, plus how the decision behind it was actually made.
///
/// In the agentic chat home a Mira turn additionally carries the specialist that
/// answered, the typed action the server decided, and whether a model actually
/// wrote the prose. `isError` marks an honest failure, so the UI never styles it
/// as an answer.
struct ConversationTurn: Identifiable, Sendable {
  enum Role: Sendable { case user, mira }

  let id: UUID
  let role: Role
  let at: Date
  let text: String
  let explanation: Explanation?
  let specialist: AgentSpecialist?
  let action: AgentAction?
  /// "muse" when a model wrote it, "unavailable" when it did not, nil for the
  /// older explanation path.
  let replySource: String?
  let isError: Bool
  /// Suggested next actions, rendered as chips. Tapping one sends it as the
  /// person's own message, so a chip can never do more than typing would.
  let chips: [String]
  /// The subject this turn belongs to ("split", "fees", "negotiation", a task
  /// id). Chips live on the last turn of their flow, not on the newest turn in
  /// the transcript: an answer keeps its actions while its subject is still the
  /// subject. Local only — a restored transcript rebuilds its own flows.
  let flow: String?
  /// A card rendered in the conversation — the payment card, when a checkout
  /// asks which card pays. Never a credential the person did not ask to see.
  let card: CardMock?
  let cardCaption: String?
  /// A document rendered in the conversation: a receipt, a swap slip, an
  /// itinerary, a reservation. The facts, laid out as the thing itself.
  let receipt: ReceiptSpec?

  /// The same turn with chips (or a card) added — an answer that turns out to
  /// be a question gets its suggestions without being rebuilt by hand.
  func with(
    chips: [String]? = nil, card: CardMock? = nil, cardCaption: String? = nil,
    receipt: ReceiptSpec? = nil, flow: String? = nil
  ) -> ConversationTurn {
    ConversationTurn(
      id: id, role: role, at: at, text: text, explanation: explanation,
      specialist: specialist, action: action, replySource: replySource, isError: isError,
      chips: chips ?? self.chips, flow: flow ?? self.flow, card: card ?? self.card,
      cardCaption: cardCaption ?? self.cardCaption, receipt: receipt ?? self.receipt)
  }

  /// The same turn with new text and a new typed action — everything that
  /// identifies the turn (id, position, time) and everything that decorates it
  /// (chips, card, receipt) stays put.
  ///
  /// An agent task's follow-up arrives as another acknowledgement of the task
  /// already on screen, and a task is exactly one card: replacing the turn in
  /// place is what stops a second, near-identical card from being appended.
  func replacing(action: AgentAction?, text: String) -> ConversationTurn {
    ConversationTurn(
      id: id, role: role, at: at, text: text, explanation: explanation,
      specialist: specialist, action: action, replySource: replySource, isError: isError,
      chips: chips, flow: flow, card: card, cardCaption: cardCaption, receipt: receipt)
  }

  init(
    id: UUID = UUID(),
    role: Role,
    at: Date = Date(),
    text: String,
    explanation: Explanation? = nil,
    specialist: AgentSpecialist? = nil,
    action: AgentAction? = nil,
    replySource: String? = nil,
    isError: Bool = false,
    chips: [String] = [],
    flow: String? = nil,
    card: CardMock? = nil,
    cardCaption: String? = nil,
    receipt: ReceiptSpec? = nil
  ) {
    self.id = id
    self.role = role
    self.at = at
    self.text = text
    self.explanation = explanation
    self.specialist = specialist
    self.action = action
    self.replySource = replySource
    self.isError = isError
    self.chips = chips
    self.flow = flow
    self.card = card
    self.cardCaption = cardCaption
    self.receipt = receipt
  }
}

/// The life of a proposed transfer, keyed by the turn that proposed it.
enum TransferProposalState: Sendable, Equatable {
  case proposed
  case sending
  case settled(receipt: String)
  case failed(String)
}

/// Which way a relay transfer moves for this app.
enum RelayDirection: Sendable { case inbound, outbound }


/// The four places money lives. The raw values are the tab keys the brand
/// themes use, so the shell can be built from the theme alone.
enum MainTab: String, Hashable, Sendable {
  case accounts
  case move
  case mira
  case you
}

/// A scoped AI permission the user can turn off.
struct AIControls: Sendable, Equatable {
  var personalizedSuggestions: Bool = true
  var remembersPreferences: Bool = true
  /// When false, Mira never calls the decision model at all.
  var assistantEnabled: Bool = true

  init() {}
}

/// A proposed automation. Always shown as a proposal, never as active bank
/// permission, and always bounded.
struct AutomationProposal: Identifiable, Sendable, Equatable {
  enum Status: String, Sendable { case proposed, revoked }

  let id: UUID
  var title: String
  var action: String
  var sourceAccount: String
  var payee: String
  var perActionCap: Money
  var aggregateCap: Money
  var expiresAt: Date
  var quoteBound: Bool
  var status: Status
  var revokedAt: Date?

  init(
    id: UUID = UUID(),
    title: String,
    action: String,
    sourceAccount: String,
    payee: String,
    perActionCap: Money,
    aggregateCap: Money,
    expiresAt: Date,
    quoteBound: Bool,
    status: Status = .proposed,
    revokedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.action = action
    self.sourceAccount = sourceAccount
    self.payee = payee
    self.perActionCap = perActionCap
    self.aggregateCap = aggregateCap
    self.expiresAt = expiresAt
    self.quoteBound = quoteBound
    self.status = status
    self.revokedAt = revokedAt
  }
}

/// The action history the brief asks the control centre to expose.
struct ActionRecord: Identifiable, Sendable {
  enum Kind: String, Sendable {
    case plan
    case payment
    case permission
    case preference
    case automation
    case data
    /// How the app itself behaved on a turn — answered from the device, a
    /// provider replayed. The kind's name is printed on the record, so it is
    /// named for what it is.
    case note
  }

  let id: UUID
  let at: Date
  let kind: Kind
  let title: String
  let detail: String

  init(id: UUID = UUID(), at: Date = Date(), kind: Kind, title: String, detail: String) {
    self.id = id
    self.at = at
    self.kind = kind
    self.title = title
    self.detail = detail
  }
}

/// A single, contextual suggestion. Never more than one at a time, and never
/// presented as an action that has already been taken.
struct MiraSuggestion: Identifiable, Sendable {
  let id: UUID
  let title: String
  let detail: String
  let actionTitle: String
  let act: CardAction.Act

  init(id: UUID = UUID(), title: String, detail: String, actionTitle: String, act: CardAction.Act) {
    self.id = id
    self.title = title
    self.detail = detail
    self.actionTitle = actionTitle
    self.act = act
  }
}

/// A row in the activity list.
struct ActivityItem: Identifiable, Sendable {
  let id: UUID
  let at: Date
  let title: String
  let subtitle: String
  /// Signed movement on the USD available account.
  let usdMovement: Money?
  let state: PaymentState?
  let payment: Payment?
  let entry: JournalEntry?

  init(
    id: UUID = UUID(),
    at: Date,
    title: String,
    subtitle: String,
    usdMovement: Money?,
    state: PaymentState?,
    payment: Payment? = nil,
    entry: JournalEntry? = nil
  ) {
    self.id = id
    self.at = at
    self.title = title
    self.subtitle = subtitle
    self.usdMovement = usdMovement
    self.state = state
    self.payment = payment
    self.entry = entry
  }
}

// MARK: - Session

private struct EverydayChatNoRoute: MiraRouteProviding {
  func route(_ message: String, baseURL: URL) async -> RoutedIntent? { nil }
}

/// The single source of truth for the running app.
///
/// Everything monetary is derived from `ledger`. The plan, the payments and the
/// activity list all read the same state, which is what stops the totals on two
/// screens from disagreeing.
@MainActor
@Observable
final class MiraSession {

  // MARK: Mode

  /// This prototype cannot move real money. Not a toggle.
  let financialMode: FinancialMode = .simulated
  /// Synthetic session id. Isolates demo state from any other session.
  let sessionId: String
  /// Shown on every decision surface.
  private(set) var lastDecisionMode: DecisionMode = .rulesOnly

  // MARK: Core state

  private(set) var ledger: Ledger
  var plan: AllocationPlan
  var context: UserContext
  private(set) var eligibilityNote: String
  private(set) var payments: [Payment] = []
  var controls = AIControls()
  var automations: [AutomationProposal] = []
  private(set) var actionHistory: [ActionRecord] = []
  var cardFrozen: Bool = false
  private(set) var conversation: [ConversationTurn] = []
  var suggestion: MiraSuggestion?

  /// Set by a screen that wants the shell to move to another tab. The shell
  /// clears it once it has, so the request is a one-shot rather than state.
  var requestedTab: MainTab?

  /// A room the app's own flows want opened, the way `requestedTab` wants a
  /// tab. The chat home clears it once it has shown the screen.
  var requestedRoute: HomeRoute?

  /// The person this session belongs to. Every screen reads the ledger, the
  /// directory, the plan and the card this profile seeded, so two people can be
  /// driven one after the other without either one's numbers surviving.
  private(set) var persona: DemoPersona

  /// Set by the menu's "Switch profile" row. The root answers it by showing the
  /// chooser; the request is cleared when the chooser closes.
  var wantsProfileChooser: Bool = false

  /// Where the last choice is remembered, so the chooser can offer one tap.
  static let profileDefaultsKey = "mira.profile"

  /// Provider state for the demo.
  var scenario: PaymentScenario = .happyPath
  private(set) var isWorking: Bool = false
  private(set) var lastError: String?

  /// The user's saved preferences, so "remove a saved preference" has meaning.
  private(set) var savedPreferences: [String: String] = [
    "Weekly discretionary": "USD 300.00",
    "Trip length": "4 weeks",
    "Home currency": "USD",
  ]

  /// The trip window, used to decide which budget week is current.
  let tripStart: Date
  let tripWeeks: Int

  // MARK: Collaborators

  private let quoteProvider = SimulatedQuoteProvider.briefFixture
  private let paymentProvider: SimulatedPaymentProvider
  private let decisionProvider: DecisionProvider
  private let composer = ExplanationComposer()
  private let agentClient = MiraAgentClient()
  private let relay = TransferRelayClient()
  private let orchestrator: MiraOrchestratorClient
  /// The route reader. Injectable so the refusal path is driven by a stub in
  /// tests rather than only by a live proxy.
  private let routeClient: any MiraRouteProviding

  /// The user's own contacts and bills, and the persisted card state.
  let localDirectory: LocalDirectoryStore

  /// Where the chosen profile is remembered. Injected so a test never writes
  /// into the app's own defaults.
  @ObservationIgnored private let defaults: UserDefaults

  /// The specialist the user pinned from the roster. When nil, Mira coordinates
  /// and routes to whichever specialist the intent selects.
  var activeAgentId: String?

  /// The carried context of an unfinished transfer request. Context, not
  /// permission: the amount still has to be confirmed by the user.
  private(set) var pendingTransfer: PendingTransferContext?

  /// How each proposed transfer is going.
  private(set) var transferProposalStates: [UUID: TransferProposalState] = [:]

  /// The most recent routed turn, for the mode strip.
  private(set) var lastOrchestration: OrchestrationResult?

  // MARK: Conversations

  /// Every persisted conversation. The active one is the transcript on screen;
  /// the others are kept so "New conversation" preserves rather than destroys.
  private(set) var threads: [StoredThread] = []
  private(set) var activeThreadId: UUID?
  @ObservationIgnored private let chatStore: ChatThreadStore
  @ObservationIgnored private let includeExampleConversation: Bool
  @ObservationIgnored private var isRestoringThread = false
  @ObservationIgnored private var liveLibraryRuns: Set<UUID> = []

  // MARK: Agent tasks

  /// Every task the app knows about, keyed by the server's task id. A task is
  /// shown only on the conversation that created it, and its progress is
  /// rendered in place rather than appended as a new turn.
  private(set) var tasks: [String: AgentTask] = [:]
  /// The last distinct progress line shown per task. A poll that repeats the
  /// previous sentence must not read as new work, so the card keeps showing the
  /// line already on screen; only a different, non-empty reading replaces it.
  private(set) var taskProgressLines: [String: String] = [:]
  @ObservationIgnored private let taskStore: AgentTaskStore
  @ObservationIgnored private var taskPollers: [String: Task<Void, Never>] = [:]
  /// Tasks with a retry in flight, so a second tap cannot start a second run.
  @ObservationIgnored private var retryingTasks: Set<String> = []
  @ObservationIgnored private var taskPollingPaused = false

  /// Cross-app demo state. Every relay transfer is applied locally exactly once,
  /// keyed by the relay's transfer id, so a restart can re-read the whole shared
  /// history without booking anything twice.
  private var relayTask: Task<Void, Never>?
  private(set) var lastReceivedFrom: String?
  private(set) var relayNotice: String?
  /// When the notice was set, so a received-transfer line can be shown briefly
  /// rather than living at the bottom of every transcript forever.
  private(set) var relayNoticeAt: Date?
  private let engine = EligibilityEngine.prototype

  private var activePaymentIndex: Int? { payments.indices.last }

  // MARK: Init

  init(
    sessionId: String = "mira-session-\(UUID().uuidString.prefix(8))",
    brand: BrandKind = .orion,
    persona explicitPersona: DemoPersona? = nil,
    decisionProvider: DecisionProvider = JevProxyClient(),
    paymentProvider: SimulatedPaymentProvider = SimulatedPaymentProvider(),
    now: Date = Date(),
    orchestrator: MiraOrchestratorClient = MiraOrchestratorClient(),
    includeExampleConversation: Bool = false,
    chatStore: ChatThreadStore = ChatThreadStore(),
    taskStore: AgentTaskStore = AgentTaskStore(),
    directory: LocalDirectoryStore = LocalDirectoryStore(),
    routeClient: (any MiraRouteProviding)? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.sessionId = sessionId
    self.decisionProvider = decisionProvider
    self.paymentProvider = paymentProvider
    self.orchestrator = orchestrator
    self.includeExampleConversation = includeExampleConversation
    self.chatStore = chatStore
    self.taskStore = taskStore
    self.localDirectory = directory
    self.routeClient = routeClient ?? MiraRouteClient.shared
    self.defaults = defaults
    self.tripStart = now
    self.tripWeeks = 4

    // The synthetic ledger. If this ever fails, the app must not start with
    // a half-built book.
    do {
      self.ledger = try Ledger.miraPrototype()
    } catch {
      fatalError("Mira could not open the ledger: \(error)")
    }

    // Which life this launch belongs to. The launch argument wins because a
    // script may not answer a question; otherwise the last choice, otherwise
    // the brand's first profile.
    let persona = explicitPersona
      ?? LaunchOptions.current.profileSlug.flatMap(DemoPersonas.persona(id:))
      ?? defaults.string(forKey: MiraSession.profileDefaultsKey)
        .flatMap(DemoPersonas.persona(id:))
      ?? DemoPersonas.defaultPersona(for: brand)
    self.persona = persona
    self.context = persona.context
    self.plan = persona.plan(total: .zero(.usd), now: now)
    self.eligibilityNote = ""

    // The directory belongs to the person. A file written for someone else — or
    // written before profiles existed — is replaced rather than mixed; a file
    // already carrying this profile keeps the edits the person made to it.
    let reseededDirectory = localDirectory.personaSlug != persona.id
    if reseededDirectory {
      localDirectory.reseed(for: persona, now: now)
    }

    seed(persona: persona, now: now)
    for entry in localDirectory.cardPurchases {
      _ = try? ledger.post(entry)
    }
    plan.total = ledger.clearedSpendableUSD
    lastOrder = localDirectory.lastOrder
    restoreConversations(droppingForeignTranscript: reseededDirectory)
    restoreTasks()
  }

  // MARK: Conversations

  /// The conversations for the History list, most recently active first.
  var threadsNewestFirst: [StoredThread] {
    threads.sorted { $0.updatedAt > $1.updatedAt }
  }

  var activeThreadTitle: String {
    threads.first { $0.id == activeThreadId }?.title ?? "New conversation"
  }

  var isShowingExampleConversation: Bool {
    threads.first { $0.id == activeThreadId }?.turns.contains { $0.replySource == "example" } == true
  }

  var hasEverydayChats: Bool {
    threads.contains { $0.collectionId == "everyday-50-v1" }
  }

  /// Build each saved chat through the same answer path as a fresh user turn.
  /// Isolated storage keeps a demonstration from freezing a card, creating a
  /// split, or changing any other state in the person's active profile.
  @discardableResult
  func loadEverydayChats() async -> Int {
    guard !hasEverydayChats else { return 0 }
    persistCurrentThread()
    var added = 0
    let baseDate = Date().addingTimeInterval(-Double(EverydayChatPrompts.all.count))
    for (index, prompt) in EverydayChatPrompts.all.enumerated() {
      let date = baseDate.addingTimeInterval(Double(index))
      if EverydayChatPrompts.onOpen.contains(prompt) {
        threads.append(StoredThread(
          id: UUID(), title: prompt, createdAt: date, updatedAt: date,
          activeAgentId: nil,
          turns: [StoredTurn(
            id: UUID(), role: "user", at: date, text: prompt,
            specialistId: nil, action: nil, replySource: nil, isError: false)],
          proposalStates: [:], pendingTo: nil, pendingAsset: nil, pendingAmountMinor: nil,
          collectionId: "everyday-50-v1"))
        added += 1
        continue
      }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mira-chat-library-\(UUID().uuidString)", isDirectory: true)
      let isolated = MiraSession(
        sessionId: "chat-library-\(index)", brand: persona.brand, persona: persona,
        orchestrator: MiraOrchestratorClient(baseURL: URL(string: "http://127.0.0.1:1")!),
        chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
        taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
        directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
        routeClient: EverydayChatNoRoute(),
        defaults: UserDefaults(suiteName: "mira-chat-library-\(UUID().uuidString)")!)
      await isolated.sendChat(prompt)
      if let answer = isolated.conversation.last, answer.role == .mira, !answer.isError {
        threads.append(StoredThread(
          id: UUID(), title: prompt, createdAt: date, updatedAt: date,
          activeAgentId: nil, turns: isolated.conversation.map(Self.storeTurn),
          proposalStates: [:], pendingTo: isolated.pendingTransfer?.to,
          pendingAsset: isolated.pendingTransfer?.asset,
          pendingAmountMinor: isolated.pendingTransfer?.amountMinor,
          collectionId: "everyday-50-v1"))
        added += 1
      }
      try? FileManager.default.removeItem(at: directory)
    }
    saveThreads()
    return added
  }

  /// Entries that need live research or saved state start when opened.
  func refreshLiveLibraryChatIfNeeded() async {
    guard let id = activeThreadId,
      let thread = threads.first(where: { $0.id == id && $0.collectionId == "everyday-50-v1" }),
      let prompt = thread.turns.first?.text,
      EverydayChatPrompts.onOpen.contains(prompt),
      !liveLibraryRuns.contains(id), !isWorking
    else { return }
    guard conversation.count == 1 || conversation.last?.isError == true else { return }
    liveLibraryRuns.insert(id)
    defer { liveLibraryRuns.remove(id) }
    if conversation.last?.isError == true {
      conversation.removeLast()
      persistCurrentThread()
    }
    await sendChatTurn(prompt, started: Date(), appendUser: false)
  }

  func openProfileStory() {
    guard let thread = threads.first(where: { thread in
      thread.turns.contains { $0.replySource == "example" }
    }) else { return }
    selectThread(thread.id)
  }

  /// Start a fresh conversation without losing the current one.
  func newConversation() {
    persistCurrentThread()
    clearRelayNotice()
    let now = Date()
    let thread = StoredThread(
      id: UUID(), title: "New conversation", createdAt: now, updatedAt: now,
      activeAgentId: nil, turns: [], proposalStates: [:],
      pendingTo: nil, pendingAsset: nil, pendingAmountMinor: nil)
    threads.append(thread)
    loadThread(thread.id)
    saveThreads()
    record(.data, "New conversation", "The previous conversation is saved in History.")
  }

  /// Switch to a stored conversation, saving the current one first.
  func selectThread(_ id: UUID) {
    guard id != activeThreadId else { return }
    persistCurrentThread()
    loadThread(id)
    saveThreads()
  }

  func deleteThread(_ id: UUID) {
    threads.removeAll { $0.id == id }
    if id == activeThreadId {
      if let next = threadsNewestFirst.first {
        loadThread(next.id)
      } else {
        let now = Date()
        let thread = StoredThread(
          id: UUID(), title: "New conversation", createdAt: now, updatedAt: now,
          activeAgentId: nil, turns: [], proposalStates: [:],
          pendingTo: nil, pendingAsset: nil, pendingAmountMinor: nil)
        threads = [thread]
        loadThread(thread.id)
      }
    }
    saveThreads()
  }

  func renameThread(_ id: UUID, to title: String) {
    guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    threads[index].title = cleaned.isEmpty ? "Conversation" : String(cleaned.prefix(60))
    saveThreads()
  }

  /// Load the stored conversations, creating a first one when there are none.
  ///
  /// A transcript belongs to the life it happened in: a file written for
  /// another profile — or written before profiles existed, when the directory
  /// had to be reseeded — is dropped rather than shown to the wrong person.
  private func restoreConversations(droppingForeignTranscript: Bool = false) {
    let payload = chatStore.load()
    let ownedByAnother = payload.profileSlug.map { $0 != persona.id } ?? false
    threads = (droppingForeignTranscript || ownedByAnother) ? [] : payload.threads
    for index in threads.indices {
      if threads[index].title == "Example conversation" {
        threads[index].title = ExampleConversation.title(for: persona)
      }
      guard threads[index].collectionId == "everyday-50-v1" else { continue }
      if let prompt = threads[index].turns.first?.text {
        threads[index].title = prompt
        if EverydayChatPrompts.shopping.contains(prompt),
          threads[index].turns.last?.role == "mira",
          threads[index].turns.last?.text.hasPrefix("I can simulate buying ") == true {
          threads[index].turns.removeLast()
        }
        if prompt == "Split USD 120 with Ana and Rui", threads[index].turns.count == 2,
          threads[index].turns.last?.role == "mira" {
          threads[index].turns.removeLast()
        }
      }
    }
    if threads.isEmpty {
      if includeExampleConversation {
        threads = [ExampleConversation.make(for: persona)]
      } else {
        let now = Date()
        threads = [StoredThread(
          id: UUID(), title: "New conversation", createdAt: now, updatedAt: now,
          activeAgentId: nil, turns: [], proposalStates: [:],
          pendingTo: nil, pendingAsset: nil, pendingAmountMinor: nil)]
      }
    }
    if includeExampleConversation && !threads.contains(where: { thread in
      thread.turns.contains { $0.replySource == "example" }
    }) {
      threads.append(ExampleConversation.make(for: persona))
    }
    let target = payload.activeThreadId.flatMap { id in
      threads.first(where: { $0.id == id && !$0.isEmpty })?.id
    } ?? threadsNewestFirst.first?.id
    if let target {
      isRestoringThread = true
      loadThread(target)
      isRestoringThread = false
    }
    saveThreads()
  }

  private func loadThread(_ id: UUID) {
    guard let thread = threads.first(where: { $0.id == id }) else { return }
    activeThreadId = id
    conversation = thread.turns.map(makeTurn)
    transferProposalStates = thread.proposalStates.reduce(into: [:]) { result, pair in
      guard let turnId = UUID(uuidString: pair.key) else { return }
      result[turnId] = TransferProposalState.decodeProposal(pair.value)
    }
    if let to = thread.pendingTo {
      pendingTransfer = PendingTransferContext(
        to: to, asset: thread.pendingAsset, amountMinor: thread.pendingAmountMinor)
    } else {
      pendingTransfer = nil
    }
    activeAgentId = thread.activeAgentId
    agentSessionId = nil
    lastAgentReply = nil
    lastAgentError = nil
    lastOrchestration = nil
    // A new or restored chat cannot inherit an unfinished action from a
    // different conversation. Those drafts are not part of StoredThread.
    checkout = nil
    pendingConversion = nil
    pendingSwap = nil
    pendingNegotiation = nil
    pendingRule = nil
    pendingRuleAction = nil
  }

  /// Snapshot the live transcript and its transfer context into the active
  /// thread. Called after every mutation, so switching threads never loses a
  /// turn and a restart finds the conversation where it was left.
  private func persistCurrentThread() {
    guard !isRestoringThread, let id = activeThreadId,
      let index = threads.firstIndex(where: { $0.id == id })
    else { return }
    threads[index].turns = conversation.map(Self.storeTurn)
    threads[index].proposalStates = transferProposalStates.reduce(into: [:]) { result, pair in
      result[pair.key.uuidString] = TransferProposalState.encodeProposal(pair.value)
    }
    threads[index].activeAgentId = activeAgentId
    threads[index].pendingTo = pendingTransfer?.to
    threads[index].pendingAsset = pendingTransfer?.asset
    threads[index].pendingAmountMinor = pendingTransfer?.amountMinor
    threads[index].updatedAt = Date()
    if threads[index].title == "New conversation" || threads[index].title.isEmpty {
      if let firstUser = conversation.first(where: { $0.role == .user }) {
        threads[index].title = Self.title(from: firstUser.text)
      }
    }
    saveThreads()
  }

  private func saveThreads() {
    chatStore.save(
      ChatThreadPayload(
        version: 1, activeThreadId: activeThreadId, threads: threads,
        profileSlug: persona.id))
  }

  private func appendTurn(_ turn: ConversationTurn) {
    conversation.append(turn)
    persistCurrentThread()
  }

  private static func title(from text: String) -> String {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return "Conversation" }
    if cleaned.count <= 44 { return cleaned }
    return String(cleaned.prefix(44)) + "…"
  }

  private static func storeTurn(_ turn: ConversationTurn) -> StoredTurn {
    StoredTurn(
      id: turn.id,
      role: turn.role == .user ? "user" : "mira",
      at: turn.at,
      text: turn.text,
      specialistId: turn.specialist?.id,
      action: turn.action,
      replySource: turn.replySource,
      isError: turn.isError,
      receipt: turn.receipt,
      chips: turn.chips,
      flow: turn.flow)
  }

  private func makeTurn(_ stored: StoredTurn) -> ConversationTurn {
    ConversationTurn(
      id: stored.id,
      role: stored.role == "user" ? .user : .mira,
      at: stored.at,
      text: stored.text,
      specialist: stored.specialistId.flatMap { id in
        AgentRoster.forBrand(persona.brand).first { $0.id == id }
      },
      action: stored.action,
      replySource: stored.replySource,
      isError: stored.isError,
      chips: stored.chips ?? (stored.receipt?.kind == .savings ? subscriptionActionChips() : []),
      flow: stored.flow ?? (stored.receipt?.kind == .savings ? "subscriptions" : nil),
      receipt: stored.receipt)
  }

  // MARK: Seeding

  /// Seed the person's whole session: their history, their opening position,
  /// their plan and their automation. Every activity entry is balanced per
  /// currency, and one brought-forward entry makes the opening balances exact
  /// rather than whatever the activity happened to sum to.
  private func seed(persona: DemoPersona, now: Date) {
    let calendar = Calendar.current
    for (index, item) in persona.activity.enumerated() {
      let day = calendar.date(byAdding: .day, value: -item.daysAgo, to: now) ?? now
      let at = calendar.date(bySettingHour: item.hour, minute: 0, second: 0, of: day) ?? day
      _ = try? ledger.post(
        JournalEntry(
          idempotencyKey: "\(persona.id)-activity-\(index)",
          date: at,
          memo: item.memo,
          references: EntryReferences(instruction: "Mira ledger"),
          postings: item.postings
        )
      )
    }

    postOpeningBalance(for: persona, now: now)

    plan = persona.plan(total: ledger.clearedSpendableUSD, now: now)
    // It is a proposal: not approved until the user approves it.
    eligibilityNote = eligibilitySummary()

    automations = [defaultAutomationProposal(weeklyBudget: plan.weeklyBudgetMoney)]
    cardFrozen = localDirectory.cardFrozen
    record(.data, "Mira is ready", "Your accounts, card and plan are in place.")

    refreshSuggestion()
  }

  /// The one entry that makes the opening figures the persona's rather than the
  /// history's: whatever the activity netted, this brings every asset to the
  /// stated balance. A real book carries a brought-forward position, and this
  /// is that line.
  private func postOpeningBalance(for persona: DemoPersona, now: Date) {
    var postings: [Posting] = []

    for asset in Asset.all {
      guard let target = persona.openingBalances[asset] else { continue }
      let current = ledger.balance(ofAsset: asset)
      let delta = target.minorUnits - current.minorUnits
      guard delta != 0 else { continue }
      postings.append(
        Posting(
          accountId: Ledger.accountId(for: asset),
          amount: Money(minorUnits: delta, currency: asset)))
      postings.append(
        Posting(
          accountId: DemoActivitySeed.externalAccount(asset),
          amount: Money(minorUnits: -delta, currency: asset)))
    }

    let pendingDelta = persona.pendingUSD.minorUnits - ledger.pendingUSD.minorUnits
    if pendingDelta != 0 {
      postings.append(
        Posting(accountId: "usd.pending", amount: Money(minorUnits: pendingDelta, currency: .usd)))
      postings.append(
        Posting(accountId: "world.usd", amount: Money(minorUnits: -pendingDelta, currency: .usd)))
    }

    guard !postings.isEmpty else { return }
    // Dated before the activity, because it is where the activity started from.
    let at =
      Calendar.current.date(byAdding: .day, value: -(persona.activity.count + 30), to: now) ?? now
    _ = try? ledger.post(
      JournalEntry(
        idempotencyKey: "\(persona.id)-opening",
        date: at,
        memo: "Balance brought forward",
        references: EntryReferences(instruction: "Mira ledger"),
        postings: postings
      )
    )
  }

  /// A proposal, not a permission: it is bounded by the person's own week and
  /// waits for their approval like the first one did.
  private func defaultAutomationProposal(weeklyBudget: Money) -> AutomationProposal {
    AutomationProposal(
      title: "Pay the same rent on the 5th",
      action: "Send one local payment",
      sourceAccount: "USD available",
      payee: SyntheticDirectory.mergedLegalName,
      perActionCap: weeklyBudget,
      aggregateCap: weeklyBudget,
      expiresAt: Date().addingTimeInterval(30 * 24 * 3600),
      quoteBound: true,
      status: .proposed
    )
  }

  // MARK: Profiles

  /// Choosing a profile from the chooser. It rebuilds the session around that
  /// person — ledger, directory, plan, card — and starts a fresh conversation:
  /// a transcript belongs to the life it happened in.
  func chooseProfile(_ persona: DemoPersona) {
    activate(persona)
  }

  /// Switching from the menu is the same rebuild, reached from another door.
  func switchProfile(_ persona: DemoPersona) {
    activate(persona)
  }

  /// The menu's "Switch profile" row asks the root for the chooser.
  func requestProfileChooser() {
    wantsProfileChooser = true
  }

  func profileChooserClosed() {
    wantsProfileChooser = false
  }

  private func activate(_ persona: DemoPersona) {
    let now = Date()

    // Stop looking at the previous person's work before any of it is replaced.
    pauseTaskPolling()
    stopRelayPolling()
    taskPollers.removeAll()
    tasks = [:]
    taskProgressLines = [:]

    self.persona = persona
    context = persona.context
    do {
      ledger = try Ledger.miraPrototype()
    } catch {
      fatalError("Mira could not open the ledger: \(error)")
    }
    payments = []
    actionHistory = []
    suggestion = nil
    pendingTransfer = nil
    transferProposalStates = [:]
    pendingConversion = nil
    pendingSwap = nil
    pendingNegotiation = nil
    pendingRule = nil
    pendingRuleAction = nil
    checkout = nil
    virtualCards = []
    lastOrder = nil
    lastOrchestration = nil
    lastAgentReply = nil
    lastAgentError = nil
    lastReceivedFrom = nil
    relayNotice = nil
    relayNoticeAt = nil
    activeAgentId = nil
    controls = AIControls()
    scenario = .happyPath
    isWorking = false
    lastError = nil

    localDirectory.reseed(for: persona, now: now)
    seed(persona: persona, now: now)

    // The previous person's threads are not carried into this one. A profile
    // is the whole session, and history is part of it.
    threads = []
    activeThreadId = nil
    conversation = []
    defaults.set(persona.id, forKey: Self.profileDefaultsKey)
    if includeExampleConversation {
      let example = ExampleConversation.make(for: persona)
      threads = [example]
      loadThread(example.id)
      saveThreads()
    } else {
      newConversation()
    }
    record(.data, "Profile changed", "This session is \(persona.name)'s now.")
  }

  // MARK: Derived state

  var clearedUSD: Money { ledger.clearedSpendableUSD }
  var pendingUSD: Money { ledger.pendingUSD.magnitude }
  var brlBalance: Money { ledger.brlBalance }

  /// The product this process is running. Read lazily from the launch-time
  /// global, so it is correct however early the session was constructed.
  var brandKind: BrandKind { CurrentBrand.theme.kind }

  /// The six specialists for this brand.
  var roster: [AgentSpecialist] { AgentRoster.forBrand(brandKind) }

  /// The specialist the current conversation is addressed to.
  var activeSpecialist: AgentSpecialist {
    AgentRoster.agent(brand: brandKind, id: activeAgentId)
  }

  /// Which budget week we are in, from the trip window.
  var currentWeekIndex: Int {
    let elapsed = Date().timeIntervalSince(tripStart)
    let week = Int(elapsed / (7 * 24 * 3600)) + 1
    return min(max(week, 1), max(plan.durationWeeks, 1))
  }

  /// The number Journey C must retrieve, not generate.
  var currentWeekRemaining: Money {
    plan.currentWeekRemaining(weekIndex: currentWeekIndex) ?? .zero(.usd)
  }

  var activePayment: Payment? {
    payments.last
  }

  var pendingAutomationCount: Int {
    automations.filter { $0.status == .proposed }.count
  }

  func snapshot() -> MiraSnapshot {
    MiraSnapshot(
      clearedUSD: clearedUSD,
      pendingUSD: ledger.pendingUSD,
      brlBalance: brlBalance,
      plan: plan,
      currentWeekIndex: currentWeekIndex,
      cardFrozen: cardFrozen,
      activePayment: activePayment,
      context: context,
      eligibilityNote: eligibilityNote,
      partialData: false
    )
  }

  /// The activity list. Built from the ledger plus any payment that has not
  /// yet produced a posting, so nothing that happened is ever hidden.
  var activity: [ActivityItem] {
    var items: [ActivityItem] = ledger.newestFirst.map { entry in
      let usd = entry.postings.first { $0.accountId == "usd.cleared" }?.amount
      let payment = payments.first { $0.draft.fingerprint == entry.references.draftFingerprint }
      return ActivityItem(
        id: entry.id,
        at: entry.date,
        title: entry.memo,
        subtitle: entry.references.providerReference.map { "Provider \($0)" } ?? "Ledger posting",
        usdMovement: usd,
        state: payment?.state,
        payment: payment,
        entry: entry
      )
    }

    // A payment sitting in a non-settled state has not posted yet and must
    // still be visible.
    for payment in payments where !payment.state.isSettled && payment.state != .draft {
      items.append(
        ActivityItem(
          id: payment.id,
          at: payment.history.last?.at ?? payment.draft.createdAt,
          title: "Local payment to \(payment.draft.payee.resolvedName ?? "unverified recipient")",
          subtitle: payment.draft.quote.allInSummary,
          usdMovement: nil,
          state: payment.state,
          payment: payment
        )
      )
    }

    return items.sorted { $0.at > $1.at }
  }

  // MARK: Plan editing

  func editAllocation(_ kind: AllocationRow.Kind, to value: Decimal) {
    plan.edit(kind, to: value, at: Date())
    record(.plan, "Plan changed", "\(kind.rawValue) set to \(value) — \(plan.status.headline)")
    refreshSuggestion()
  }

  func setDuration(weeks: Int) {
    plan.durationWeeks = max(1, weeks)
    plan.durationUpdatedAt = Date()
    plan.rebuildWeeks()
    record(.plan, "Trip length changed", "\(plan.durationWeeks) weeks — \(plan.status.headline)")
    refreshSuggestion()
  }

  /// Approving records consent for this plan revision. It does not authorize
  /// an investment or a payment.
  func approvePlan() {
    guard plan.status.isBalanced else {
      lastError = plan.status.headline
      return
    }
    let consent = "consent-plan-\(UUID().uuidString.prefix(8))"
    plan.approve(at: Date(), consentId: consent)
    record(
      .plan, "Plan approved",
      "Consent \(consent). This does not authorize a payment or an investment.")
    refreshSuggestion()
  }

  // MARK: Journey B — payment

  /// Loads the bundled sample Pix request: BRL 150.00.
  func loadSampleRequest() async {
    let payee = await resolvePayee(
      handle: SyntheticDirectory.anaHandle, invoiceLabel: SyntheticDirectory.anaInvoiceLabel)
    await preparePayment(
      payee: payee, recipientAmount: Money(majorUnits: 150, currency: .brl),
      instruction: "Bundled sample Pix request · BRL 150.00")
  }

  /// Prepares a payment from pasted instruction text. Extraction is
  /// deliberately conservative: an amount is only taken from an explicit
  /// currency figure, and the recipient is always the provider's answer.
  func prepareFromPastedText(_ text: String) async {
    let extracted = InstructionParser.parse(text)
    let handle = extracted.handle ?? SyntheticDirectory.unknownHandle
    let payee = await resolvePayee(
      handle: handle, invoiceLabel: extracted.label ?? "Unknown recipient")
    let amount = extracted.amount ?? Money(majorUnits: 150, currency: .brl)
    await preparePayment(payee: payee, recipientAmount: amount, instruction: text)
  }

  func prepareForAmbiguousPayee() async {
    let payee = await resolvePayee(
      handle: SyntheticDirectory.ambiguousHandle, invoiceLabel: "J. Silva")
    await preparePayment(
      payee: payee, recipientAmount: Money(majorUnits: 150, currency: .brl),
      instruction: "Ambiguous recipient")
  }

  private func resolvePayee(handle: String, invoiceLabel: String) async -> Payee {
    let verification = await paymentProvider.resolvePayee(handle: handle)
    return Payee(
      id: handle,
      label: invoiceLabel,
      handle: handle,
      institution: "Banco Simulado S.A.",
      verification: verification
    )
  }

  private func preparePayment(payee: Payee, recipientAmount: Money, instruction: String) async {
    do {
      let quote = try quoteProvider.quote(forRecipientAmount: recipientAmount)
      let draft = PaymentDraft(payee: payee, quote: quote, instruction: instruction)
      let payment = Payment(draft: draft)
      payments.append(payment)
      record(
        .payment,
        "Payment prepared",
        "\(recipientAmount.display) to \(payee.resolvedName ?? "an unverified recipient"). Draft \(draft.shortFingerprint). Nothing sent."
      )
      refreshSuggestion()
    } catch {
      lastError = "Could not quote this payment: \(error)"
    }
  }

  /// Gets a fresh quote for the active payment, which also invalidates any
  /// earlier approval because the draft fingerprint changes.
  func refreshQuote() async {
    guard let index = activePaymentIndex else { return }
    let existing = payments[index]
    do {
      let quote = try quoteProvider.quote(forRecipientAmount: existing.draft.quote.recipientAmount)
      let draft = PaymentDraft(
        payee: existing.draft.payee, quote: quote, instruction: existing.draft.instruction)
      var replacement = Payment(draft: draft)
      if existing.state.isSettled {
        payments[index] = existing
        return
      }
      replacement.history = existing.history + replacement.history
      payments[index] = replacement
      record(
        .payment, "Quote refreshed",
        "New quote for \(quote.recipientAmount.display). Any earlier approval no longer applies.")
    } catch {
      lastError = "Could not refresh the quote: \(error)"
    }
  }

  /// Approves the exact draft currently held. A real user gesture is required.
  /// Discards the active draft.
  ///
  /// Nothing was sent, so nothing is being reversed: this removes a local draft
  /// only. A payment already in flight cannot be discarded.
  func discardActivePayment() {
    guard let index = activePaymentIndex else { return }
    let payment = payments[index]
    guard !payment.state.isInFlightOrBeyond else {
      lastError =
        "This payment has already been submitted. A settled transfer cannot be undone from this app."
      return
    }
    payments.remove(at: index)
    record(
      .payment, "Draft discarded",
      "Draft \(payment.draft.shortFingerprint) removed. Nothing had been sent.")
    refreshSuggestion()
  }

  func approveDraft(userGesture: Bool = true) {
    guard let index = activePaymentIndex else { return }
    do {
      let consent = "consent-payment-\(UUID().uuidString.prefix(8))"
      try payments[index].approve(consentId: consent, at: Date(), userGesture: userGesture)
      record(
        .payment,
        "Draft approved",
        "Consent \(consent) bound to draft \(payments[index].draft.shortFingerprint). Nothing sent yet."
      )
    } catch {
      lastError = "Could not approve: \(error)"
    }
  }

  /// Submits an approved payment and reconciles whatever the provider
  /// eventually reports.
  func confirmPayment() async {
    guard let index = activePaymentIndex else { return }
    let now = Date()

    let confirmability = payments[index].confirmability(at: now, availableFunds: clearedUSD)
    guard confirmability.isReady else {
      if case .blocked(let error, let reason) = confirmability {
        lastError = "\(error.headline): \(reason)"
      }
      return
    }

    let payment = payments[index]
    let submission = PaymentSubmission(
      idempotencyKey: payment.idempotencyKey,
      draftFingerprint: payment.draft.fingerprint,
      recipientHandle: payment.draft.payee.handle,
      recipientName: payment.draft.payee.resolvedName ?? "",
      recipientAmount: payment.draft.quote.recipientAmount,
      debitAmount: payment.draft.quote.conversionDebit,
      fee: payment.draft.quote.fee,
      quoteId: payment.draft.quote.id,
      consentId: payment.approval?.consentId ?? ""
    )

    do {
      try payments[index].transition(to: .submitting, at: now, note: "Handing to the provider")
    } catch {
      lastError = "Could not submit: \(error)"
      return
    }

    await paymentProvider.setScenario(scenario)
    isWorking = true
    record(
      .payment, "Payment submitted", "Provider \(payments[index].idempotencyKey). Not a result yet."
    )
    let outcome = await paymentProvider.submit(submission)
    isWorking = false

    await apply(outcome: outcome, at: Date())

    // Poll for a definite state. A pending payment is not settled.
    await settleLoop()
  }

  /// Reconciles an unknown status. This is the only correct response to a
  /// timeout: find out what actually happened before considering a retry.
  func reconcile() async {
    guard let index = activePaymentIndex else { return }
    let payment = payments[index]
    // Always reconcile on our own idempotency key. After a timeout no provider
    // reference was ever received, and the key is what survives that gap.
    let key = payment.idempotencyKey
    let reference = payment.state.providerReference

    isWorking = true
    let outcome = await paymentProvider.reconcile(idempotencyKey: key)
    isWorking = false

    record(
      .payment,
      "Reconciled with provider",
      reference.map { "Matched provider reference \($0) using idempotency key \(key)." }
        ?? "No provider reference was ever received, so this was matched on idempotency key \(key)."
    )
    await apply(outcome: outcome, at: Date())
    // If reconciliation resolved to "still pending", keep watching until the
    // provider reaches a definite state.
    await settleLoop()
  }

  /// Replays the provider's event for the active payment. Used by the
  /// duplicate-event branch to prove the ledger does not debit twice.
  func replayProviderEvent() async {
    guard let index = activePaymentIndex else { return }
    let key = payments[index].idempotencyKey
    guard let outcome = await paymentProvider.replayEvent(idempotencyKey: key) else {
      lastError = "The provider has no record of that submission."
      return
    }
    record(.note, "Provider replayed its event", "A repeated event must not debit twice.")
    await apply(outcome: outcome, at: Date())
  }

  private func settleLoop(maxAttempts: Int = 12) async {
    for _ in 0..<maxAttempts {
      guard let index = activePaymentIndex else { return }
      switch payments[index].state {
      case .pending:
        try? await Task.sleep(nanoseconds: 450_000_000)
        let outcome = await paymentProvider.reconcile(
          idempotencyKey: payments[index].idempotencyKey)
        await apply(outcome: outcome, at: Date())
      default:
        return
      }
    }
  }

  /// Applies a provider outcome to payment state and, on settlement, to the
  /// ledger and the plan — exactly once.
  private func apply(outcome: ProviderOutcome, at now: Date) async {
    guard let index = activePaymentIndex else { return }
    let current = payments[index].state

    switch outcome {
    case .pending(let ref):
      if case .pending = current { return }
      try? payments[index].transition(
        to: .pending(providerReference: ref), at: now, note: "Provider accepted, not settled")

    case .settled(let ref, let settledAt):
      try? payments[index].transition(
        to: .settled(providerReference: ref, settledAt: settledAt), at: now,
        note: "Provider reported settled")
      postSettlement(for: payments[index], at: settledAt)

    case .failed(let ref, let reason):
      try? payments[index].transition(
        to: .failed(providerReference: ref, reason: reason), at: now, note: reason)
      record(.payment, "Payment failed", reason)

    case .noResponse(let note):
      try? payments[index].transition(
        to: .statusUnknown(providerReference: current.providerReference, note: note),
        at: now,
        note: note
      )
      record(
        .payment, "Status unknown",
        "\(note) The payment may or may not have been sent. Reconcile before retrying.")
    }

    refreshSuggestion()
  }

  /// Posts the settlement to the ledger and records the spend against the
  /// budget week. Idempotent: the ledger ignores a repeated key.
  private func postSettlement(for payment: Payment, at date: Date) {
    let quote = payment.draft.quote
    let key = "settle:\(payment.id.uuidString)"

    let entry = JournalEntry(
      idempotencyKey: key,
      date: date,
      memo: "Local payment to \(payment.draft.payee.resolvedName ?? "recipient")",
      references: EntryReferences(
        instruction: payment.draft.instruction,
        draftFingerprint: payment.draft.fingerprint,
        providerReference: payment.state.providerReference,
        consentId: payment.approval?.consentId
      ),
      postings: [
        Posting(
          accountId: "usd.cleared",
          amount: Money(minorUnits: -quote.totalDebit.minorUnits, currency: .usd)),
        Posting(accountId: "fees.usd", amount: quote.fee),
        Posting(accountId: "fx.clearing", amount: quote.conversionDebit),
        Posting(
          accountId: "fx.clearing.brl",
          amount: Money(minorUnits: -quote.recipientAmount.minorUnits, currency: .brl)),
        Posting(accountId: "brl.cleared", amount: quote.recipientAmount),
      ]
    )

    do {
      let posted = try ledger.post(entry)
      guard posted else {
        record(
          .note, "Duplicate settlement ignored",
          "The ledger already applied \(key). No second debit.")
        return
      }
    } catch {
      // A prototype must never silently swallow a book that will not balance.
      lastError = "Ledger rejected the settlement: \(error)"
      record(.payment, "Settlement rejected by the ledger", "\(error)")
      return
    }

    // The discretionary budget absorbs settled spending.
    plan.total = ledger.clearedSpendableUSD
    plan.recordSpend(quote.totalDebit, weekIndex: currentWeekIndex)

    record(
      .payment,
      "Payment settled",
      "\(quote.totalDebit.display) debited. Recipient received \(quote.recipientAmount.display). Available is now \(clearedUSD.display)."
    )
  }

  // MARK: Demo controls

  /// Simulates an incoming deposit that has *not* cleared. It must never
  /// become available funds.
  func simulatePendingDeposit(_ amount: Money = Money(minorUnits: 150_000, currency: .usd)) {
    let key = "mira-pending-\(UUID().uuidString.prefix(6))"
    do {
      try ledger.post(
        JournalEntry(
          idempotencyKey: key,
          date: Date(),
          memo: "Incoming deposit · pending",
          references: EntryReferences(instruction: "Mira · incoming deposit"),
          postings: [
            Posting(
              accountId: "world.usd", amount: Money(minorUnits: -amount.minorUnits, currency: .usd)),
            Posting(accountId: "usd.pending", amount: amount),
          ]
        )
      )
      record(
        .note, "Deposit on its way",
        "\(amount.display) is on its way. It joins your available balance when it clears.")
      refreshSuggestion()
    } catch {
      lastError = "Could not simulate the deposit: \(error)"
    }
  }

  /// Clears a pending deposit, which is the only way it becomes spendable.
  func clearPendingDeposit() {
    let pending = ledger.pendingUSD
    guard !pending.isZero else {
      lastError = "There is nothing pending to clear."
      return
    }
    let key = "mira-clear-\(UUID().uuidString.prefix(6))"
    do {
      try ledger.post(
        JournalEntry(
          idempotencyKey: key,
          date: Date(),
          memo: "Deposit · cleared",
          references: EntryReferences(instruction: "Mira · deposit cleared"),
          postings: [
            Posting(
              accountId: "usd.pending",
              amount: Money(minorUnits: -pending.minorUnits, currency: .usd)),
            Posting(accountId: "usd.cleared", amount: pending),
          ]
        )
      )
      plan.total = ledger.clearedSpendableUSD
      record(.note, "Pending deposit cleared", "\(pending.display) became available.")
      refreshSuggestion()
    } catch {
      lastError = "Could not clear the deposit: \(error)"
    }
  }

  /// Demo affordance: replaces the active draft's quote with one whose window
  /// has already closed, so the expired branch can be shown on stage instead of
  /// waiting out a real lifetime.
  ///
  /// Rebuilding the draft replaces its fingerprint, which is exactly what
  /// invalidates any earlier approval.
  func expireActiveQuote() {
    guard let index = activePaymentIndex else { return }
    let payment = payments[index]
    guard !payment.state.isInFlightOrBeyond else {
      lastError = "That payment has already been submitted, so its quote no longer matters."
      return
    }

    do {
      let expired = try SimulatedQuoteProvider(
        rate: payment.draft.quote.rate,
        feeUSD: payment.draft.quote.fee,
        lifetime: 60
      ).quote(
        forRecipientAmount: payment.draft.quote.recipientAmount,
        now: Date().addingTimeInterval(-600)
      )

      let draft = PaymentDraft(
        payee: payment.draft.payee,
        quote: expired,
        instruction: payment.draft.instruction
      )
      var replacement = Payment(draft: draft)
      replacement.history = payment.history + replacement.history
      payments[index] = replacement

      record(
        .note,
        "Quote expired",
        "The draft now carries a closed quote. A new one is needed before anything can be sent."
      )
    } catch {
      lastError = "Could not expire the quote: \(error)"
    }
  }

  func setScenario(_ scenario: PaymentScenario) async {
    self.scenario = scenario
    await paymentProvider.setScenario(scenario)
    record(.note, "Provider scenario set", scenario.displayName)
  }

  /// Ask the shell to move. Used by cards and buttons that start a flow
  /// belonging to another tab.
  func requestTab(_ tab: MainTab) {
    requestedTab = tab
  }

  // MARK: The agent

  /// Continuity for the agent conversation. Held in the session so a follow-up
  /// question lands in the same context, and cleared when the conversation is.
  private(set) var agentSessionId: String?
  private(set) var lastAgentReply: AgentReply?
  private(set) var lastAgentError: String?

  /// A digest of everything the agent is allowed to know.
  ///
  /// This is the whole of its world: if a figure is not in here, the agent has
  /// been told not to produce it. Transaction memos are included because they
  /// are the point, and the proxy fences them as data.
  /// True when the message is asking Mira to go and find, compare or prepare
  /// something, rather than asking a specialist their own question. Deliberately
  /// the same vocabulary the runtime routes on, so the two cannot disagree about
  /// what counts as a task.
  static func looksLikeTaskRequest(_ message: String) -> Bool {
    let text = message.lowercased()
    let verbs = [
      "find", "search", "look for", "looking for", "where can i", "where to",
      "best ", "recommend", "compare", "options", "a good", "prepare",
      "book ", "reserve a", "reservation", "plan a", "plan my", "itinerary",
      "flight", "flights", "fly ", "hotel", "stay", "airbnb", "trip",
      "restaurant", "dinner", "lunch", "buy ", "shop", "purchase", "price of",
      "cheapest", "deal", "research", "what is the best",
    ]
    return verbs.contains { text.contains($0) }
  }

  /// The handful of facts the on-device assistant needs. Built from the same
  /// values the screens read, so a spoken figure and a printed figure can never
  /// disagree.
  func standaloneSnapshot() -> StandaloneSnapshot {
    StandaloneSnapshot(
      appName: appName,
      available: MoneyFormatter.amount(clearedUSD),
      holdings: ledger.holdings()
        .filter { $0.asset != .usd && $0.amount.minorUnits != 0 }
        .map { "\($0.asset.code) \(MoneyFormatter.amount($0.amount))" },
      recent: ledger.newestFirst.prefix(4).map { entry in
        // Some memos already carry the figure ("Sent to Mira Orion · USD 25.00");
        // repeating it reads like a machine wrote it.
        if entry.memo.range(of: "[0-9]", options: .regularExpression) != nil { return entry.memo }
        guard let movement = entry.postings.first(where: { $0.amount.isNegative })?.amount
        else { return entry.memo }
        return "\(movement.magnitude.display) · \(entry.memo)"
      },
      contacts: localDirectory.contacts.map(\.name),
      bills: localDirectory.bills.map { "\($0.name) · day \($0.dueDay)" },
      weekLeft: currentWeekRemaining.display,
      weeklyBudget: plan.weeklyBudgetMoney.display,
      reserve: plan.reserveMoney.display,
      unallocated: plan.unallocated.display,
      planApproved: plan.isApproved,
      cardFrozen: cardFrozen
    )
  }

  func stateDigest() -> String {
    var lines: [String] = []

    lines.append("BALANCES")
    for (asset, amount) in ledger.holdings() where amount.minorUnits != 0 {
      lines.append("\(asset.code) \(MoneyFormatter.amount(amount))")
    }
    lines.append("pending USD \(MoneyFormatter.amount(ledger.pendingUSD))")

    lines.append("")
    lines.append("PLAN")
    lines.append(
      "Week \(currentWeekIndex) of \(plan.durationWeeks). Weekly budget \(plan.weeklyBudgetMoney.display). Left this week \(currentWeekRemaining.display)."
    )
    lines.append(
      "Reserve \(plan.reserveMoney.display). Known bills \(plan.knownBillsMoney.display). Unallocated \(plan.unallocated.display)."
    )
    lines.append("Plan approved: \(plan.isApproved ? "yes" : "no").")

    lines.append("")
    lines.append("CARD")
    lines.append("Card is \(cardFrozen ? "frozen" : "active").")

    if !localDirectory.bills.isEmpty {
      lines.append("")
      lines.append("USER'S OWN BILLS")
      for bill in localDirectory.bills {
        lines.append("Day \(bill.dueDay)  \(bill.name)  \(bill.amount.display)")
      }
    }

    if !localDirectory.contacts.isEmpty {
      lines.append("")
      lines.append("USER'S OWN CONTACTS")
      for contact in localDirectory.contacts {
        lines.append("\(contact.name)  \(contact.handle)")
      }
    }

    if let payment = activePayment {
      lines.append("")
      lines.append("PAYMENT IN PROGRESS")
      lines.append(
        "\(payment.state.label): \(payment.draft.quote.recipientAmount.display) to \(payment.draft.payee.resolvedName ?? "unverified recipient") at \(payment.draft.quote.rateLabel)."
      )
    }

    lines.append("")
    lines.append("RECENT TRANSACTIONS (newest first)")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    for entry in ledger.newestFirst.prefix(30) {
      let movement = entry.postings
        .filter { Ledger.accountId(for: $0.amount.currency) == $0.accountId }
        .map { $0.amount }
        .first
      let amountText = movement.map { MoneyFormatter.display($0) } ?? ""
      lines.append(
        "\(formatter.string(from: entry.date))  \(entry.memo)  \(amountText)")
    }

    return lines.joined(separator: "\n")
  }

  /// Ask the agent. The reply is shown as-is; anything the digest did not
  /// support is contradicted by the card beside it.
  func askAgent(_ message: String) async {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    guard controls.assistantEnabled else {
      lastAgentError = "The assistant is switched off in Controls."
      return
    }

    appendTurn(ConversationTurn(role: .user, text: trimmed))
    isWorking = true
    lastAgentError = nil

    // Give the model the last few turns so a follow-up has context. Kept short:
    // the digest is the substance, this is only pronoun resolution.
    let history = conversation.suffix(6).map { turn in
      MiraOrchestratorClient.WireTurn(
        role: turn.role == .user ? "user" : "assistant", content: turn.text)
    }

    let result = await agentClient.ask(
      message: trimmed,
      digest: stateDigest(),
      brand: brandKind,
      agentId: activeAgentId ?? AgentRoster.coordinator(brandKind).id,
      agentSessionId: agentSessionId,
      history: history
    )
    isWorking = false

    switch result {
    case .success(let reply):
      lastAgentReply = reply
      record(.note, "Mira answered", "\(reply.model) · \(reply.latencyMs) ms")
      appendTurn(
        ConversationTurn(
          role: .mira, text: reply.say, specialist: activeSpecialist, replySource: "muse"))

    case .failure(let error):
      // No canned answer. The failure is the message.
      lastAgentError = error.message
      appendTurn(
        ConversationTurn(role: .mira, text: error.message, isError: true)
      )
      record(.note, "Agent unavailable", error.message)
    }
  }

  // MARK: Agentic chat

  /// The chat home's send. One call to the proxy does the whole turn: Jev labels
  /// the intent, deterministic code chooses the specialist and the typed action,
  /// the model writes the prose.
  ///
  /// If the user has pinned a specialist, the turn goes straight to that agent
  /// through the single-specialist route instead.
  /// A conversion Mira has offered to price and is still waiting on: the person
  /// said which currencies, and has not yet said how much. Without this, the
  /// answer to "100 eur" was a balance.
  private(set) var pendingConversion: (from: Asset, to: Asset)?

  /// A priced swap waiting for a yes. "Yes" acts on this exact quote — the rate
  /// and fee the person was shown — and never on a number a model retold.
  private(set) var pendingSwap: SwapQuote?

  /// A prepared renewal ask waiting for its outcome. The document was shown
  /// with it; "they said yes" records against that ask, not against nothing.
  private(set) var pendingNegotiation: Negotiation.Ask?

  /// A rule the app read from a sentence, waiting for the person to approve the
  /// structured contract — not the sentence.
  private(set) var pendingRule: RuleContract?

  /// A rule's action, prepared and waiting for one word. The amount it would
  /// apply to is part of the record, so "apply it" acts on exactly what was shown.
  private(set) var pendingRuleAction: (rule: RuleContract, amount: Money?, line: String)?

  /// Window-style triggers fire at most once a day per rule+subject, so opening
  /// the app five times is one run.
  private var ruleFiredAt: [String: Date] = [:]

  /// A checkout in progress: where it goes, which card pays, one last yes.
  private(set) var checkout: CheckoutDraft?

  /// Virtual cards made in this session, newest last. Demo artefacts.
  private(set) var virtualCards: [CardMock] = []

  /// The last order this session placed, so "track it" has something to track.
  private(set) var lastOrder: PlacedOrder?

  /// The brand's card, with the live freeze state.
  var mainCard: CardMock {
    var base = brandKind == .orion ? CardMock.orion : CardMock.aurea
    base = CardMock(
      id: base.id, nickname: base.nickname, holder: base.holder, pan: base.pan,
      expiry: base.expiry, cvv: base.cvv, network: base.network, kind: base.kind,
      frozen: cardFrozen)
    return base
  }

  /// The app's own end-to-end timing for the last turn: from the moment Send
  /// was tapped to the moment the reply landed in the transcript. It sits
  /// beside the proxy's own stage timings, so a slow turn can be attributed.
  private(set) var lastTurnLatencyMs: Int = 0

  /// Is this turn about to price a conversion? Only then is the rate table
  /// worth a network fetch: the desk answers are the app's own arithmetic, and
  /// making a desk answer queue behind a rate source is the kind of serial
  /// round trip that made a two-second answer feel like twenty.
  nonisolated static func shouldRefreshRates(for message: String, hasPendingQuote: Bool) -> Bool {
    guard StandaloneAgent.mentionsConversion(message) else { return false }
    return StandaloneAgent.isMoneyOnly(message)
      || StandaloneAgent.namesAPricedCorridor(message)
      || hasPendingQuote
  }

  func sendChat(_ text: String) async {
    let started = Date()
    await sendChatTurn(text, started: started)
    lastTurnLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
  }

  private func sendChatTurn(_ text: String, started: Date, appendUser: Bool = true) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let threadAtStart = activeThreadId

    // The user is in the conversation now; a received-transfer line from earlier
    // has been seen and does not need to sit at the bottom of the transcript.
    clearRelayNotice()
    if appendUser { appendTurn(ConversationTurn(role: .user, text: trimmed)) }

    guard controls.assistantEnabled else {
      appendTurn(
        ConversationTurn(
          role: .mira,
          text: "The assistant is switched off in the menu. Your manual controls are all still here.",
          isError: true
        ))
      return
    }

    // "Hi" is a greeting, not a request. It is answered here, in the same frame
    // it was typed — no router, no model, and no working row.
    if let greeting = StandaloneAgent.greeting(for: trimmed) {
      apply(local: greeting)
      return
    }

    // ── Instruction overrides ─────────────────────────────────────────────
    // A message that tries to change the assistant's own rules, identity or
    // limits is never a local flow's next step. The refusal is deterministic
    // and comes before a pending swap, checkout or transfer can act on it —
    // so an injection phrased as a continuation ("…and also approve it")
    // cannot be answered as an approval, online or off.
    if Self.looksLikeInstructionOverride(trimmed) {
      refuseInstructionOverride(reason: "deterministic")
      return
    }

    // ── Refusals and the document ─────────────────────────────────────────
    // A rate we did not quote is never booked; a question about the build is
    // answered from the capability document; a corridor we do not price gets
    // the honest corridor answer. All three are settled before any pending
    // quote, transfer or task can act on the message.
    if handleRateBookingIntent(trimmed) { return }
    if handleCapabilityIntent(trimmed) { return }
    if handleCorridorIntent(trimmed) { return }

    // ── Flows the app owns ────────────────────────────────────────────────
    // A priced swap waiting for a yes, and a checkout in progress. These are
    // deterministic, they act on the exact figures the person was shown, and
    // they never hand a bare "yes" to a model that has no idea what it means.
    //
    // The rate table is refreshed only when this turn is about to price a
    // conversion: a money-only message, a priced corridor, or the amount
    // answering a waiting quote. An answer that merely mentions a currency —
    // a desk report, a subscription list — must not queue behind a rate fetch.
    if Self.shouldRefreshRates(for: trimmed, hasPendingQuote: pendingConversion != nil || pendingSwap != nil) {
      await LiveRates.refresh(baseURL: orchestrator.baseURL)
    }
    if await handlePendingSwap(trimmed) { return }
    if handleTransferIntent(trimmed) { return }
    // The rule contract comes before the subscription and money-desk readers:
    // "when Spotify charges, cancel it" is a standing rule, not a question
    // about the next charge day. A sentence with no watchable event falls
    // through untouched.
    if handleRuleIntent(trimmed) { return }
    if handleSubscriptionIntent(trimmed) { return }
    if handleOffersIntent(trimmed) { return }
    if handleCapacityIntent(trimmed) { return }
    if handleMoneyDeskIntent(trimmed) { return }
    if handleConsentSetting(trimmed) { return }
    if await handleCheckout(trimmed) { return }
    if handleTrackIntent(trimmed) { return }

    // A pinned specialist answers their own kind of question — but the app's
    // own flows come first: a swap waiting for a yes, a checkout, a transfer, a
    // subscription, an offer, or anything the money desk knows how to answer
    // belongs to the app, not to whoever happens to be pinned.
    if let agentId = activeAgentId, !MiraSession.looksLikeTaskRequest(trimmed),
      !StandaloneAgent.looksLikeMoneyMovement(trimmed),
      !StandaloneAgent.mentionsConversion(trimmed)
    {
      await askSpecialist(trimmed, agentId: agentId)
      return
    }
    if activeAgentId != nil {
      activeAgentId = nil
      record(.note, "Back to Mira", "A task request unpins the specialist.")
    }

    // ── Ask Jev where the answer lives ────────────────────────────────────
    // One typed decision, a few hundred milliseconds: in the app's own records,
    // in a short reply, or on the web. Answered from the device when it is a
    // record question — that is what makes ordinary asks feel instant, and it is
    // the router's whole purpose.
    let routedIntent = await routeClient.route(trimmed, baseURL: orchestrator.baseURL)
    guard activeThreadId == threadAtStart else { return }
    if let routed = routedIntent {
      switch routed.route {
      case "advice":
        appendTurn(
          ConversationTurn(
            role: .mira,
            text:
              "That is investment advice and I do not give it — nobody should, without knowing your whole position. "
              + "I can show you what you hold, what a fee costs you, and the public facts about anything you name.",
            specialist: activeSpecialist, replySource: "deterministic"))
        return

      case "refuse":
        // The proxy refused: the message tried to change the assistant's own
        // rules, identity or limits. The refusal outranks anything local the
        // message matched, and every pending flow it could have hijacked is
        // dropped before any of them runs.
        refuseInstructionOverride(reason: routed.reason)
        return

      case "instant":
        if let answer = StandaloneAgent.recordAnswer(
          needs: routed.needs, message: trimmed, snapshot: standaloneSnapshot())
        {
          if let pending = StandaloneAgent.pendingPair(
            for: trimmed, snapshot: standaloneSnapshot())
          {
            pendingConversion = pending
          }
          apply(local: answer)
          record(.note, "Answered from this device", "jev \(routed.needs)")
          return
        }

      case "research":
        break   // the task path below is the research path

      default:
        break   // a short reply: the model writes it
      }
    }

    // "100 eur" after "I need EUR from my USD" is the amount for that
    // conversion, not a new question.
    // The amount a quote was waiting for has to be an amount, not a number
    // inside a new sentence.
    if let pending = pendingConversion, StandaloneAgent.isAmountOnly(trimmed),
      let request = StandaloneAgent.amountRequest(trimmed),
      let priced = StandaloneAgent.pricePendingConversion(
        from: pending.from, to: pending.to, value: request.value, statedIn: request.asset)
    {
      pendingConversion = nil
      apply(local: priced)
      return
    }

    // Money questions and conversions are computed here: they are exact, they
    // are the same figures the screens show, and they should not wait on a
    // server or a model to be right.
    if let local = StandaloneAgent.localAnswer(for: trimmed, snapshot: standaloneSnapshot()) {
      apply(local: local)
      record(.note, "Answered from this device", local.model)
      // A rate with no amount is an offer: remember the pair so the next number
      // prices it.
      pendingConversion = StandaloneAgent.pendingPair(for: trimmed, snapshot: standaloneSnapshot())
      return
    }

    isWorking = true
    let history = transcriptHistory()
    let result = await orchestrator.orchestrate(
      message: trimmed,
      digest: stateDigest(),
      brand: brandKind,
      sessionId: sessionId,
      conversationId: activeThreadId?.uuidString ?? sessionId,
      pending: pendingTransfer,
      history: history,
      // Where they are, when the app knows: a search for a shop should look
      // near them, not on whichever continent answered first.
      place: localDirectory.mainAddress?.text
    )
    isWorking = false
    guard activeThreadId == threadAtStart else { return }

    switch result {
    case .success(let routed):
      apply(routed: routed, userMessage: trimmed)

    case .failure(let error):
      // No proxy on this network — the normal case on a phone. The app answers
      // what it can from its own state, then asks the model directly.
      if await answerStandalone(trimmed, specialist: nil) { return }

      lastAgentError = error.message
      appendTurn(ConversationTurn(role: .mira, text: error.message, isError: true))
      record(.note, "Mira could not route this", error.message)
    }
  }

  /// Answers without the proxy, when there is no proxy to reach: first from the
  /// app's own state (a balance, a budget, the card, receiving details), then
  /// from the model directly with a key held on this device. Returns true when
  /// the turn was answered.
  private func answerStandalone(_ message: String, specialist: AgentSpecialist?) async -> Bool {
    if let local = StandaloneAgent.localAnswer(for: message, snapshot: standaloneSnapshot()) {
      isWorking = false
      if let specialist {
        appendTurn(
          ConversationTurn(
            role: .mira, text: local.say, specialist: specialist, replySource: "deterministic"))
      } else {
        apply(local: local)
      }
      record(.note, "Mira answered from this device", local.model)
      return true
    }

    isWorking = true
    let spoken = transcriptHistory().suffix(6).map {
      ($0.role == "user" ? "user" : "assistant", $0.content)
    }
    let direct = await DirectModel.ask(message, snapshot: standaloneSnapshot(), history: spoken)
    isWorking = false
    guard let direct else { return false }

    lastAgentReply = AgentReply(say: direct.say, model: direct.model, latencyMs: direct.latencyMs)
    appendTurn(
      ConversationTurn(
        role: .mira, text: direct.say, specialist: specialist ?? activeSpecialist,
        replySource: "muse"))
    record(.note, "Mira answered on the device", "\(direct.model) · \(direct.latencyMs) ms")
    return true
  }

  /// Applies an answer the app produced itself — a typed action plus its line.
  ///
  /// Built here rather than on a server, but in the same shape, so every screen
  /// downstream behaves identically whether the answer came from the proxy, from
  /// the device's own state, or from the model directly.
  private func apply(local: StandaloneAnswer) {
    // A priced swap is a question with a number in it: remember the exact quote
    // so a "yes" right after acts on it.
    if let quote = local.quote {
      pendingSwap = quote
    }
    let action = local.action ?? AgentAction(kind: .reply)
    let routed = OrchestrationResult(
      intent: Intent(rawValue: action.kind.rawValue) ?? intentForStandalone(action, local.say),
      decisionMode: .rulesOnly,
      specialist: activeSpecialist,
      action: action,
      say: local.say,
      source: local.model == "on-device" ? "deterministic" : "muse",
      model: local.model,
      latencyMs: local.latencyMs
    )
    apply(routed: routed, userMessage: "")
    // A quote is a question with a number in it: offer the two answers.
    if local.quote != nil, let last = conversation.last, last.role == .mira {
      conversation[conversation.count - 1] = last.with(chips: ["Swap it", "Cancel"], flow: "swap")
    }
  }

  /// The typed action maps to the intent it stands for; a plain reply is
  /// "ambiguous" only in the technical sense that no ledger command was implied.
  private func intentForStandalone(_ action: AgentAction, _ say: String) -> Intent {
    switch action.kind {
    case .showBalance: return .balance
    case .showBudget, .proposeBudgetUpdate: return .budget
    case .openCardControls: return .cardHelp
    case .openReceive: return .receive
    case .proposeTransfer, .askTransferDetails: return .preparePayment
    case .requirementsFlow: return .support
    default: return .ambiguous
    }
  }

  /// A direct conversation with one named specialist, from the roster.
  func askSpecialist(_ text: String, agentId: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if conversation.last?.role != .user || conversation.last?.text != trimmed {
      appendTurn(ConversationTurn(role: .user, text: trimmed))
    }

    let specialist = AgentRoster.agent(brand: brandKind, id: agentId)

    // A question the app can answer exactly — a balance, a budget, a card, a
    // conversion — is answered here, at once, before any network is involved.
    if let local = StandaloneAgent.localAnswer(for: trimmed, snapshot: standaloneSnapshot()) {
      appendTurn(
        ConversationTurn(
          role: .mira, text: local.say, specialist: specialist, replySource: "deterministic"))
      record(.note, "Answered from this device", local.model)
      return
    }

    isWorking = true
    let result = await agentClient.ask(
      message: trimmed,
      digest: stateDigest(),
      brand: brandKind,
      agentId: agentId,
      agentSessionId: agentSessionId,
      history: transcriptHistory()
    )
    isWorking = false

    switch result {
    case .success(let reply):
      agentSessionId = reply.agentSessionId ?? agentSessionId
      appendTurn(
        ConversationTurn(
          role: .mira, text: reply.say, specialist: specialist, replySource: "muse"))
      record(.note, "\(specialist.name) answered", "\(reply.model) · \(reply.latencyMs) ms")

    case .failure(let error):
      if await answerStandalone(trimmed, specialist: specialist) { return }
      lastAgentError = error.message
      appendTurn(
        ConversationTurn(role: .mira, text: error.message, specialist: specialist, isError: true))
      record(.note, "\(specialist.name) unavailable", error.message)
    }
  }

  /// Apply a Mira turn to the transcript under the one-task-one-card rule.
  ///
  /// A follow-up answer ("Next week") can come back as another acknowledgement
  /// of the task already on screen. That turn replaces the existing one in
  /// place — same position, same id — so the conversation never grows a second
  /// card for the same work. Everything else appends as before.
  ///
  /// Pure, so the rule is testable without a server.
  static func applying(
    _ turn: ConversationTurn, to turns: [ConversationTurn]
  ) -> (turns: [ConversationTurn], replaced: Bool) {
    guard turn.action?.kind == .agentTask, let taskId = turn.action?.taskId, !taskId.isEmpty,
      let index = turns.lastIndex(where: {
        $0.action?.kind == .agentTask && $0.action?.taskId == taskId
      })
    else { return (turns + [turn], false) }
    var updated = turns
    updated[index] = turns[index].replacing(action: turn.action, text: turn.text)
    return (updated, true)
  }

  /// The same rule for an acknowledgement that carries a *new* task id for work
  /// already on screen: the server can start a fresh run of the same subject
  /// (a failed attempt is retried by answering its question, for example), and
  /// the card must stay one card. The subject is the task's own title — the
  /// server writes it from the request — and the newest matching card is the
  /// one replaced. Returns the replaced task id so its record and poller can be
  /// retired with it.
  ///
  /// Pure, so the rule is testable without a server.
  static func applyingContinuation(
    _ turn: ConversationTurn, to turns: [ConversationTurn]
  ) -> (turns: [ConversationTurn], replacedTaskId: String?)? {
    guard turn.action?.kind == .agentTask,
      let newId = turn.action?.taskId, !newId.isEmpty,
      let title = Self.normalisedTaskTitle(turn.action?.taskTitle), !title.isEmpty,
      let index = turns.lastIndex(where: { existing in
        guard existing.action?.kind == .agentTask,
          let existingId = existing.action?.taskId, existingId != newId
        else { return false }
        return Self.normalisedTaskTitle(existing.action?.taskTitle) == title
      })
    else { return nil }
    var updated = turns
    let replacedId = updated[index].action?.taskId
    updated[index] = turns[index].replacing(action: turn.action, text: turn.text)
    return (updated, replacedId)
  }

  private static func normalisedTaskTitle(_ raw: String?) -> String? {
    let clean = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return clean.isEmpty ? nil : clean
  }

  /// Applies a routed turn: carries transfer context, appends the turn and
  /// records the typed action. No action here moves money on its own.
  private func apply(routed: OrchestrationResult, userMessage: String) {
    lastOrchestration = routed
    lastDecisionMode = routed.decisionMode

    switch routed.action.kind {
    case .askTransferDetails:
      pendingTransfer = PendingTransferContext(
        to: routed.action.to, asset: nil, amountMinor: nil)
    case .proposeTransfer:
      pendingTransfer = PendingTransferContext(
        to: routed.action.to, asset: routed.action.assetCode,
        amountMinor: routed.action.amountMinor)
    default:
      pendingTransfer = nil
    }

    let line = routed.say.isEmpty ? "I could not produce an answer for that." : routed.say
    let turn = ConversationTurn(
      role: .mira,
      text: line,
      specialist: routed.specialist,
      action: routed.action,
      replySource: routed.source,
      isError: false
    )
    // A task is exactly one card: an acknowledgement of a task already in this
    // conversation replaces its turn in place rather than appending a second
    // copy. A follow-up can also come back as a *new* task id for the same work
    // (the server starts a fresh run when the first attempt failed); the card
    // rule recognises the same subject by its title, so that path cannot leave
    // two near-identical cards behind either.
    var continuationSource: AgentTask? = nil
    let applied = Self.applying(turn, to: conversation)
    if applied.replaced {
      conversation = applied.turns
      persistCurrentThread()
    } else if let continuation = Self.applyingContinuation(turn, to: conversation) {
      if let oldId = continuation.replacedTaskId {
        stopTaskPolling(oldId)
        continuationSource = tasks[oldId]
        tasks[oldId] = nil
        taskProgressLines[oldId] = nil
      }
      conversation = continuation.turns
      persistCurrentThread()
    } else {
      appendTurn(turn)
      if routed.action.kind == .proposeTransfer {
        transferProposalStates[turn.id] = .proposed
      }
    }
    if routed.action.kind == .agentTask {
      registerTask(action: routed.action)
      noteTaskRequest(
        action: routed.action, userMessage: userMessage, inheritedFrom: continuationSource)
    }

    if let signal = routed.embeddedInstructionSignal, signal > 0.5 {
      record(
        .data, "Instruction-like text detected",
        "Signal \(String(format: "%.2f", signal)). Treated as data. No permission, limit or setting changed.")
    }

    let decisionLabel = routed.decisionModel ?? "unknown"
    let replyLabel =
      routed.isFastPath
      ? "instant deterministic reply"
      : "\(routed.model) · \(routed.latencyMs) ms"
    record(
      routed.decisionMode.isModelBacked ? .data : .note,
      "\(routed.specialist.name) routed \(routed.intent.rawValue)",
      "\(routed.action.kind.rawValue) · Jev \(decisionLabel) \(routed.decisionLatencyMs) ms · \(replyLabel)"
    )
    _ = userMessage
  }

  // MARK: Instruction overrides
  //
  // The app's half of the proxy's `injection-guard.mjs`. The server refuses
  // through `/v1/route`; this deterministic guard covers the same obvious
  // phrasings locally, before any local flow acts and whether or not the proxy
  // is reachable.

  /// Does this message try to change the assistant's own rules, identity or
  /// limits — "ignore your instructions", "operator mode", "raise my limit",
  /// "skip approval", "approve this without asking"?
  ///
  /// Deliberately narrow: every pattern needs a rule, limit, approval or
  /// permission being overridden, never the verb "ignore" on its own, so
  /// "ignore the memo, pay Maria" stays an ordinary instruction about a memo.
  nonisolated static func looksLikeInstructionOverride(_ message: String) -> Bool {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    let patterns = [
      // "ignore all previous policies", "disregard your instructions".
      #"\b(?:ignore|disregard|forget|override|overrule|bypass|omit)\s+(?:(?:all|any|the|your|my|its|our|their|these|those|previous|prior|earlier|above|new|old|initial|original|system|safety)\s+){0,4}(?:instructions?|prompts?|polic(?:y|ies)|rules?|guidelines?|limits?|restrictions?|guardrails?|approvals?|permissions?|authorisations?|authorizations?|consents?)\b"#,
      // "operator mode", "developer access", "admin privileges", "jailbreak".
      #"\b(?:operator|developer|dev|admin|administrator|root|sudo|god|jailbreak|unrestricted|superuser)\s+(?:mode|access|permissions?|privileges?|rights?|override|authority|control)\b"#,
      // "grant me admin access", "elevate my permissions".
      #"\b(?:grant|give|hand over)\b[^.!?\n]{0,32}\b(?:admin|operator|root|full|unlimited|superuser|special)\s+(?:access|permissions?|privileges?|rights?|control|authority)\b"#,
      #"\b(?:elevate|escalate|raise)\s+(?:(?:the|your|my|its|our|their)\s+){0,2}(?:permissions?|privileges?|rights?|access|authority|clearance)\b"#,
      // "skip approval", "bypass the confirmation", "no approval needed".
      #"\b(?:skip|skipping|bypass|bypassing|avoid|avoiding|remove|removing|drop|dropping|waive|waiving|no)\s+(?:(?:the|your|my|any|all|its|our|their|his|her|that|this|need for|more)\s+){0,2}(?:approvals?|authorisations?|authorizations?|permissions?|confirmations?|consents?|authority)\b"#,
      // "approve this without asking", "send it without confirmation".
      #"\b(?:approve|authorise|authorize|confirm|execute|proceed|do|send|pay|transfer|place|buy|swap|move)\b[^.!?\n]{0,40}\b(?:without asking|without confirmation|without checking|without your approval|no questions asked|without any questions)\b"#,
      // "raise my limit", "increase the cap", "override the maximum".
      #"\b(?:raise|raising|increase|increasing|lift|lifting|remove|removing|change|changing|update|updating|override|overriding|exceed|exceeding)\s+(?:(?:the|your|my|its|our|their|his|her|that|this)\s+){0,2}(?:limits?|caps?|ceilings?|thresholds?|maximum|max)\b"#,
      // "change your rules", "rewrite your instructions".
      #"\b(?:change|changing|modify|modifying|rewrite|rewriting|replace|replacing|update|updating)\s+(?:(?:the|your|my|its|our|their|his|her|that|these|those)\s+){0,2}(?:rules?|instructions?|prompts?|polic(?:y|ies)|identity|persona|guidelines?|limits?|configuration)\b"#,
      // "reveal your system prompt", "show me your instructions".
      #"\b(?:reveal|show|print|repeat|leak|display|give me|tell me)\b[^.!?\n]{0,24}\b(?:system prompt|hidden prompt|initial prompt|original prompt|your (?:instructions?|prompt|rules))\b"#,
      // A line that opens like a document injection: "New instructions: …".
      #"^\s*(?:new|updated|revised|additional|important|system)\s+(?:instructions?|rules?|polic(?:y|ies)|directives?)\s*[::]"#,
    ]
    return patterns.contains {
      text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  /// Refuse an instruction-override attempt: the deterministic line, no model,
  /// and every pending flow the message could have been aimed at is dropped.
  /// Nothing is echoed back, and no permission, limit or approval moves.
  private func refuseInstructionOverride(reason: String?) {
    pendingSwap = nil
    pendingConversion = nil
    pendingTransfer = nil
    pendingRule = nil
    pendingRuleAction = nil
    checkout = nil
    isWorking = false
    appendTurn(
      ConversationTurn(
        role: .mira,
        text: MiraRouteClient.refusalLine,
        replySource: "deterministic"))
    record(
      .data, "Refused an instruction-override attempt",
      "No rule, limit or approval changed; any pending flow was dropped. (\(reason ?? "deterministic"))")
  }

  /// The transcript as model turns, oldest first, capped for the wire.
  private func transcriptHistory() -> [MiraOrchestratorClient.WireTurn] {
    conversation.suffix(8).map { turn in
      MiraOrchestratorClient.WireTurn(
        role: turn.role == .user ? "user" : "assistant", content: turn.text)
    }
  }

  // MARK: Agent tasks
  //
  // A research turn comes back as an acknowledgement plus a task id. The task's
  // progress is polled and rendered on the turn that created it, scoped to this
  // conversation. A completed task never appends a new turn and never opens a
  // new conversation: the card in place is the whole interface.

  /// The runtime's placeholder summary: it says work has started, not what the
  /// work is. It is never treated as a progress reading.
  static let placeholderProgress = "Researching live sources now."

  /// The line to show for a task's newest progress reading.
  ///
  /// Pure, so the rule is testable without a session. An empty reading (a
  /// resumed run the server has not described yet) keeps the previous distinct
  /// line, and a repeat of the last line keeps it too — the same words must not
  /// be re-rendered as if they were news. Only a different, non-empty line
  /// becomes the new line.
  static func distinctProgress(previous: String?, incoming: String) -> String? {
    let candidate = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return previous }
    return candidate == previous ? previous : candidate
  }

  /// Remember the newest distinct progress line for a task. Called from every
  /// path that stores a task reading, so the card's line is the newest distinct
  /// reading rather than whatever the last poll happened to carry.
  ///
  /// Only an active task has progress: a completed task's summary is its
  /// answer, and remembering it would show that answer as a spinner line if
  /// the same id were resumed.
  private func noteProgress(for task: AgentTask) {
    guard task.status.isActive else { return }
    let incoming = task.summary
    guard incoming.trimmingCharacters(in: .whitespacesAndNewlines) != Self.placeholderProgress,
      let line = Self.distinctProgress(previous: taskProgressLines[task.id], incoming: incoming),
      line != taskProgressLines[task.id]
    else { return }
    taskProgressLines[task.id] = line
  }

  /// Store one task reading. The single funnel for `tasks`, so the progress
  /// bookkeeping can never drift from the record the card renders.
  /// Internal rather than private: the retry tests seed a failed record directly.
  func storeTask(_ task: AgentTask) {
    tasks[task.id] = task
    noteProgress(for: task)
  }

  /// The task behind a turn's action, or nil when the task is not part of the
  /// conversation currently on screen. This is the thread-isolation boundary.
  func task(for action: AgentAction) -> AgentTask? {
    guard let id = action.taskId, !id.isEmpty, let task = tasks[id] else { return nil }
    guard AgentTaskScope.isVisible(task, in: activeThreadId) else { return nil }
    return task
  }

  /// A brief received-transfer line is worth showing when it happens and not
  /// worth showing forever, so it is only rendered for a short window.
  var relayNoticeIsFresh: Bool {
    guard let at = relayNoticeAt else { return false }
    return Date().timeIntervalSince(at) < 60
  }

  private func clearRelayNotice() {
    relayNotice = nil
    relayNoticeAt = nil
  }

  /// Record the acknowledgement that arrived with a routed turn and begin
  /// polling it. The turn already carries the id, so a restored transcript can
  /// rebuild the same association without the server.
  private func registerTask(action: AgentAction) {
    guard let id = action.taskId, !id.isEmpty else { return }
    let now = Date()
    var task = tasks[id] ?? AgentTask(
      id: id,
      brand: brandKind.rawValue,
      status: AgentTask.Status(rawValue: action.taskStatus ?? "") ?? .queued,
      title: action.taskTitle ?? "",
      threadId: activeThreadId,
      createdAt: now,
      updatedAt: now)
    if task.threadId == nil { task.threadId = activeThreadId }
    if task.brand.isEmpty { task.brand = brandKind.rawValue }
    if let status = action.taskStatus.flatMap(AgentTask.Status.init(rawValue:)) {
      task.status = status
    }
    if let title = action.taskTitle, !title.isEmpty { task.title = title }
    // The acknowledgement is not the task: it carries an id, a title and a
    // status, never the question, summary, steps or sources. Mark the record
    // un-hydrated so the poller fetches the real task once — even when this
    // acknowledged status already looks terminal — and restart any waiting
    // poller so a follow-up that reuses the id resumes and replaces the old
    // question and results.
    task.isHydrated = false
    task.updatedAt = now
    storeTask(task)
    persistTasks()
    stopTaskPolling(id)
    startTaskPolling(id)
  }

  /// Record what the person asked for, so a retry can re-run it. The ask is the
  /// first message; the refinement is the newest. A continuation that arrives
  /// under a new task id inherits the ask from the card it replaces.
  private func noteTaskRequest(
    action: AgentAction, userMessage: String, inheritedFrom: AgentTask?
  ) {
    guard let id = action.taskId, !id.isEmpty, var task = tasks[id] else { return }
    let message = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.request == nil { task.request = inheritedFrom?.request }
    if task.lastInput == nil { task.lastInput = inheritedFrom?.lastInput }
    if !message.isEmpty {
      if task.request == nil { task.request = message }
      task.lastInput = message
    }
    task.updatedAt = Date()
    storeTask(task)
    persistTasks()
  }

  /// Begin polling one task. The first reading is immediate, because the
  /// acknowledgement that arrived with the turn never contains the question,
  /// summary, steps or sources. A terminal status therefore does not stop the
  /// poller from starting: one fetch always has to run. After that reading a
  /// terminal task stops and an active one keeps polling with backoff.
  func startTaskPolling(_ id: String) {
    guard taskPollers[id] == nil, !taskPollingPaused else { return }
    guard tasks[id] != nil else { return }
    taskPollers[id] = Task { [weak self] in
      var attempt = 0
      var consecutiveFailures = 0
      var hydrated = false
      while !Task.isCancelled {
        // Immediate first fetch; every later one backs off.
        if hydrated || consecutiveFailures > 0 {
          let delay = TaskPollBackoff.delay(
            attempt: consecutiveFailures > 0 ? attempt + 2 : attempt)
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          if Task.isCancelled { return }
        }
        guard let self else { return }
        let outcome = await self.orchestrator.task(id: id, brand: self.brandKind)
        if Task.isCancelled { return }
        guard let existing = self.tasks[id] else { return }
        switch outcome {
        case .success(let wire):
          let merged = existing.applying(wire)
          self.storeTask(merged)
          self.persistTasks()
          hydrated = true
          consecutiveFailures = 0
          // A watch that returned a new check is a rule trigger. The subject is
          // the thing being watched, not the task's raw title.
          if merged.watch?.lastCheckAt != existing.watch?.lastCheckAt,
            merged.watch?.lastOk != false
          {
            self.evaluateRules(
              trigger: .watchResult, subject: Reminders.watchName(for: merged), amount: nil)
          }
          if merged.status.isTerminal { self.taskPollers[id] = nil; return }
          attempt += 1
        case .failure(let error):
          consecutiveFailures += 1
          let message: String
          switch error {
          case .notFound:
            message = "The task service has not answered yet."
          case .unavailable(let detail):
            message = detail
          }
          var tracked = existing.tracking(message)
          tracked.status = existing.status
          self.storeTask(tracked)
          self.persistTasks()
          // Keep trying while the reason looks transient; stop after a run of
          // failures and let the card offer an explicit retry.
          if consecutiveFailures >= 12 {
            self.taskPollers[id] = nil
            return
          }
          attempt += 1
        }
      }
    }
  }

  /// Stop polling one task without touching its state.
  func stopTaskPolling(_ id: String) {
    taskPollers[id]?.cancel()
    taskPollers[id] = nil
  }

  /// Ask the server to cancel a task. The answer is the task as it stands.
  func cancelTask(_ id: String) async {
    stopTaskPolling(id)
    switch await orchestrator.cancelTask(id: id, brand: brandKind) {
    case .success(let wire):
      storeTask(tasks[id]?.applying(wire) ?? wire)
    case .failure(let error):
      guard var existing = tasks[id] else { break }
      switch error {
      case .notFound:
        existing = existing.tracking("The task service has not answered yet.")
      case .unavailable(let detail):
        existing = existing.tracking(detail)
      }
      storeTask(existing)
    }
    persistTasks()
  }

  /// Retry a failed task. This is not just another poll: a poll of a failed
  /// task returns the same failure forever. The task service is asked to run it
  /// again first; when it has no retry route, the app re-runs the task's own
  /// request through the route that created it. Either way a real run starts,
  /// and the card stays one card.
  func retryTask(_ id: String) async {
    guard !retryingTasks.contains(id) else { return }
    guard var task = tasks[id], TaskRetry.isWorthRetrying(task) else { return }
    retryingTasks.insert(id)
    defer { retryingTasks.remove(id) }
    stopTaskPolling(id)
    task.pollError = nil
    storeTask(task)
    persistTasks()

    switch await orchestrator.retryTask(id: id, brand: brandKind) {
    case .success(let wire):
      storeTask(task.applying(wire))
      persistTasks()
      startTaskPolling(id)

    case .failure(let error):
      await rerunTask(task, serviceError: error)
    }
  }

  /// The fallback retry: send the task's own request back through the
  /// orchestrator (the service route that creates and continues tasks). No user
  /// bubble is added — the retry re-runs what the person already said — and the
  /// acknowledgement lands through the normal one-card rule.
  private func rerunTask(_ task: AgentTask, serviceError: TaskFetchError) async {
    guard
      let plan = TaskRetry.plan(for: task, in: conversation, threadId: activeThreadId)
    else {
      var failed = tasks[task.id] ?? task
      failed = failed.tracking(
        serviceError == .notFound
          ? "The task service has not answered yet."
          : "I could not find the request to run again.")
      storeTask(failed)
      persistTasks()
      return
    }

    isWorking = true
    let result = await orchestrator.orchestrate(
      message: plan.message,
      digest: stateDigest(),
      brand: brandKind,
      sessionId: sessionId,
      conversationId: activeThreadId?.uuidString ?? sessionId,
      pending: nil,
      history: transcriptHistory(),
      place: localDirectory.mainAddress?.text
    )
    isWorking = false

    switch result {
    case .success(let routed):
      apply(routed: routed, userMessage: "")
    case .failure(let error):
      guard var failed = tasks[plan.taskId] else { return }
      failed = failed.tracking(error.message)
      storeTask(failed)
      persistTasks()
    }
  }

  /// Run a standing watch's next check now. The card updates from the server's
  /// answer and polling resumes, because a check is a run.
  func checkWatchNow(_ id: String) async {
    switch await orchestrator.checkWatch(id: id, brand: brandKind) {
    case .success(let wire):
      storeTask(tasks[id]?.applying(wire) ?? wire)
      startTaskPolling(id)
    case .failure(let error):
      guard var existing = tasks[id] else { break }
      switch error {
      case .notFound:
        existing = existing.tracking("The task service has not answered yet.")
      case .unavailable(let detail):
        existing = existing.tracking(detail)
      }
      storeTask(existing)
    }
    persistTasks()
    scheduleReminderRefresh()
  }

  /// Stop a standing watch. The last check stays on the card.
  func stopWatch(_ id: String) async {
    stopTaskPolling(id)
    switch await orchestrator.stopWatch(id: id, brand: brandKind) {
    case .success(let wire):
      storeTask(tasks[id]?.applying(wire) ?? wire)
    case .failure(let error):
      guard var existing = tasks[id] else { break }
      switch error {
      case .notFound:
        existing = existing.tracking("The task service has not answered yet.")
      case .unavailable(let detail):
        existing = existing.tracking(detail)
      }
      storeTask(existing)
    }
    persistTasks()
    scheduleReminderRefresh()
  }

  /// Polling is suspended while the app is not frontmost, and resumed with the
  /// same durable task ids when it returns.
  func pauseTaskPolling() {
    taskPollingPaused = true
    for poller in taskPollers.values { poller.cancel() }
    taskPollers.removeAll()
  }

  func resumeTaskPolling() {
    taskPollingPaused = false
    // An un-hydrated task is fetched once even when its acknowledged status is
    // terminal; a hydrated active task keeps polling.
    for task in tasks.values where AgentTaskPollPolicy.shouldPoll(task) {
      startTaskPolling(task.id)
    }
  }

  private func restoreTasks() {
    let payload = taskStore.load()
    tasks = Dictionary(payload.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    // Each restored task's last reading is the line its card will show; noting
    // it now keeps that reading from looking like new progress on first poll.
    for task in tasks.values { noteProgress(for: task) }
    // A thread's turns are durable too. If a task record is missing (an older
    // build, or a lost task file) rebuild the association from the turn that
    // created it, so polling can still resume.
    for thread in threads {
      for turn in thread.turns {
        guard let action = turn.action, action.kind == .agentTask,
          let id = action.taskId, !id.isEmpty, tasks[id] == nil
        else { continue }
        let now = Date()
        storeTask(
          AgentTask(
            id: id,
            brand: brandKind.rawValue,
            status: action.taskStatus.flatMap(AgentTask.Status.init(rawValue:)) ?? .queued,
            title: action.taskTitle ?? "",
            threadId: thread.id,
            createdAt: turn.at,
            updatedAt: now))
      }
    }
  }

  private func persistTasks() {
    taskStore.save(AgentTaskPayload(version: 1, tasks: Array(tasks.values)))
  }

  /// Pin a specialist so the next turns go straight to them.
  func openSpecialist(_ agent: AgentSpecialist) {
    activeAgentId = agent.id
    agentSessionId = nil
    appendTurn(
      ConversationTurn(
        role: .mira,
        text: "\(agent.name) here — \(agent.role.lowercased()). What do you need?",
        specialist: agent,
        replySource: "scripted"
      ))
  }

  /// Return to Mira coordinating the whole roster.
  func releaseSpecialist() {
    activeAgentId = nil
    agentSessionId = nil
    persistCurrentThread()
  }

  // MARK: Transfer confirmation

  /// Confirm the exact proposal on a turn. The idempotency key is derived from
  /// the turn, so a retry after a timeout can never book the same transfer twice.
  func confirmTransfer(for turnId: UUID) async {
    guard let turn = conversation.first(where: { $0.id == turnId }),
      let action = turn.action, action.kind == .proposeTransfer,
      let asset = action.asset, let amount = action.amount
    else { return }
    if case .sending = transferProposalStates[turnId] { return }
    if case .settled = transferProposalStates[turnId] { return }

    // Never substitute a recipient. The server only proposes a transfer with an
    // explicit, supported counterparty; if that is somehow missing, stop.
    guard let destination = action.to else {
      let message = "The recipient is missing, so I will not guess one."
      transferProposalStates[turnId] = .failed(message)
      lastError = message
      persistCurrentThread()
      return
    }

    // Re-check against the app's own ledger first. The relay owns the real
    // limit, but the app should not even ask when it can see it will fail.
    let available = ledger.balance(ofAsset: asset)
    guard amount.minorUnits <= available.minorUnits else {
      let message = "Not enough \(asset.code). Available \(available.display)."
      transferProposalStates[turnId] = .failed(message)
      lastError = message
      persistCurrentThread()
      return
    }

    transferProposalStates[turnId] = .sending
    persistCurrentThread()
    let outcome = await relay.transfer(
      idempotencyKey: "mira-xfer-\(turnId.uuidString)",
      from: appName,
      to: destination,
      asset: asset,
      amount: amount,
      note: "From \(appName)"
    )

    switch outcome {
    case .settled(let transfer), .duplicate(let transfer):
      _ = applyRelayTransfer(transfer, direction: .outbound)
      let line = "\(amount.display) to \(destination). Receipt \(transfer.id)."
      transferProposalStates[turnId] = .settled(receipt: transfer.id)
      pendingTransfer = nil
      appendTurn(
        ConversationTurn(
          role: .mira,
          text: "Sent \(line) on your approval.",
          specialist: turn.specialist ?? activeSpecialist,
          action: AgentAction(
            kind: .transferReceipt,
            to: transfer.to,
            from: transfer.from,
            assetCode: transfer.assetCode,
            amountMinor: transfer.amountMinor,
            transferId: transfer.id,
            receiptLine: line,
            isSimulated: true
          ),
          replySource: "deterministic"
        ))
      record(.payment, "Transfer settled", line)

    case .rejected(let code, _):
      let message = outcome.userMessage ?? "The transfer was refused (\(code))."
      transferProposalStates[turnId] = .failed(message)
      lastError = message
      appendTurn(
        ConversationTurn(
          role: .mira, text: message, specialist: turn.specialist ?? activeSpecialist, isError: true))

    case .unreachable(let detail):
      transferProposalStates[turnId] = .failed(detail)
      lastError = detail
      appendTurn(
        ConversationTurn(
          role: .mira, text: detail, specialist: turn.specialist ?? activeSpecialist, isError: true))
    }
  }

  func cancelTransfer(for turnId: UUID) {
    guard case .proposed = transferProposalStates[turnId] ?? .failed("") else { return }
    transferProposalStates[turnId] = .failed("Cancelled by you. Nothing was sent.")
    pendingTransfer = nil
    persistCurrentThread()
    record(.note, "Transfer cancelled", "The proposal was dropped before anything moved.")
  }

  /// Apply a budget change the user approved from a proposal card.
  func applyBudgetUpdate(amountMinor: Int64) {
    let amount = Money(minorUnits: amountMinor, currency: .usd)
    plan.edit(.discretionary, to: amount.majorUnits, at: Date())
    plan.rebuildWeeks()
    record(.plan, "Weekly budget changed", "Discretionary set to \(amount.display).")
    appendTurn(
      ConversationTurn(
        role: .mira,
        text: "Done — your weekly discretionary budget is now \(amount.display).",
        specialist: activeSpecialist, replySource: "deterministic"))
  }

  /// Toggle the simulated card freeze from a card-control card.
  func toggleCardFreeze() {
    setCardFrozen(!cardFrozen)
  }

  /// The other product on the shared demo ledger. It is shown in the UI and
  /// offered as a recipient, but it is never substituted for a recipient the
  /// user did not name.
  var otherAppName: String {
    brandKind == .aurea ? "Mira Orion" : "Mira Aurea"
  }

  // MARK: Journey C — conversation

  /// Reports which decision mode is actually available, before any decision
  /// has been made. Never claims a model answered when it did not.
  func refreshDecisionAvailability() async {
    guard controls.assistantEnabled else {
      lastDecisionMode = .rulesOnly
      return
    }
    guard let client = decisionProvider as? JevProxyClient else {
      lastDecisionMode = .rulesOnly
      return
    }
    lastDecisionMode = await client.availabilityMode() ?? .rulesOnly
  }

  /// Routes a question and composes a grounded answer.
  ///
  /// The routing label comes from the provider. Every number in the answer
  /// comes from `snapshot()`.
  func ask(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    appendTurn(ConversationTurn(role: .user, text: trimmed))

    guard controls.assistantEnabled else {
      let decision = DecisionResult(
        intent: .ambiguous, confidence: nil, probabilities: [:],
        needsClarification: nil, embeddedInstructionSignal: nil,
        mode: .rulesOnly, resolvedModel: nil, latencyMs: 0,
        detail:
          "Personalized suggestions are switched off in the control centre, so Mira did not classify this."
      )
      appendTurn(
        ConversationTurn(
          role: .mira,
          text: "The assistant is switched off. The same actions are on the buttons.",
          explanation: composer.compose(decision: decision, snapshot: snapshot())
        )
      )
      return
    }

    isWorking = true
    let state = redactedState(for: trimmed)
    let decision = await decisionProvider.classify(state: state, sessionId: sessionId)
    isWorking = false

    lastDecisionMode = decision.mode
    let explanation = composer.compose(decision: decision, snapshot: snapshot())

    record(
      decision.mode.isModelBacked ? .data : .note,
      "Decision made",
      "\(decision.mode.label) · \(decision.latencyMs) ms · routed \(decision.intent.rawValue)"
    )

    // An embedded-instruction signal is surfaced, never obeyed.
    if let signal = decision.embeddedInstructionSignal, signal > 0.5 {
      record(
        .data,
        "Instruction-like text detected",
        "Signal \(String(format: "%.2f", signal)). Treated as data. No permission, limit or setting changed."
      )
    }

    appendTurn(
      ConversationTurn(role: .mira, text: explanation.headline, explanation: explanation)
    )
  }

  /// The minimum synthetic state needed for routing. No identifiers, no tax
  /// numbers, no card data, no documents.
  private func redactedState(for question: String) -> String {
    """
    Synthetic demo session. Corridor: USD income, spending in BRL, user present in \(context.presentLocation.name), resident in \(context.legalResidence.name).
    Available USD: \(MoneyFormatter.display(clearedUSD)).
    Plan: bills \(MoneyFormatter.display(plan.knownBillsMoney)), reserve \(MoneyFormatter.display(plan.reserveMoney)), weekly \(MoneyFormatter.display(plan.weeklyBudgetMoney)) for \(plan.durationWeeks) weeks.
    This week remaining: \(MoneyFormatter.display(currentWeekRemaining)).
    User message: \(question)
    """
  }

  // MARK: Control centre

  func setPersonalizedSuggestions(_ enabled: Bool) {
    controls.personalizedSuggestions = enabled
    record(
      .permission,
      enabled ? "Personalized suggestions enabled" : "Personalized suggestions disabled",
      enabled
        ? "Mira may rank contextual suggestions again."
        : "Mira will not rank contextual suggestions.")
    refreshSuggestion()
  }

  func setAssistantEnabled(_ enabled: Bool) {
    controls.assistantEnabled = enabled
    record(
      .permission, enabled ? "Assistant enabled" : "Assistant disabled",
      enabled ? "The decision model may be called." : "No decision model will be called.")
  }

  func setRemembersPreferences(_ enabled: Bool) {
    controls.remembersPreferences = enabled
    if !enabled {
      savedPreferences.removeAll()
    }
    record(
      .preference, enabled ? "Preference memory enabled" : "Preference memory disabled",
      enabled ? "Mira keeps your saved preferences." : "All saved preferences were removed.")
  }

  func removePreference(_ key: String) {
    savedPreferences.removeValue(forKey: key)
    record(.preference, "Preference removed", "“\(key)” no longer informs suggestions.")
  }

  func revokeAutomation(_ id: UUID) {
    guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
    automations[index].status = .revoked
    automations[index].revokedAt = Date()
    record(
      .automation, "Revoked: \(automations[index].title)",
      "A revoked automation does not execute. This revocation is in your history.")
    refreshSuggestion()
  }

  func setCardFrozen(_ frozen: Bool) {
    cardFrozen = frozen
    localDirectory.setCardFrozen(frozen)
    record(
      .permission, frozen ? "Card frozen" : "Card unfrozen",
      frozen
        ? "Charges are declined until you unfreeze it. Mira will tell you if a charge is attempted."
        : "Your card is live again. Mira watches the charges and flags anything that looks wrong.")
  }

  /// Credit an incoming transfer from outside this app.
  ///
  /// This is the receiving end of the two-app demo: when Aurea sends, Orion
  /// books the matching inflow here. The posting is a real double entry against
  /// the external counterparty, so the balance moves for the same reason it
  /// would in production.
  @discardableResult
  func receiveExternalTransfer(
    asset: Asset,
    amount: Money,
    from: String,
    idempotencyKey: String? = nil
  ) -> Bool {
    guard amount.currency == asset, amount.minorUnits > 0 else { return false }
    // Keyed on the sender's transfer id when there is one, so repeated polls and
    // app restarts can never credit the same transfer twice.
    let key =
      idempotencyKey
      ?? "xfer-in-\(asset.code)-\(amount.minorUnits)-\(Int(Date().timeIntervalSince1970))"
    do {
      let posted = try ledger.post(
        JournalEntry(
          idempotencyKey: key,
          date: Date(),
          memo: "Received from \(from)",
          references: EntryReferences(instruction: "Inbound \(asset.code) transfer"),
          postings: [
            Posting(accountId: "world.\(asset.code.lowercased())",
                    amount: Money(minorUnits: -amount.minorUnits, currency: asset)),
            Posting(accountId: Ledger.accountId(for: asset), amount: amount),
          ]
        )
      )
      if posted {
        record(.payment, "Received \(amount.display)", "Inbound \(asset.code) transfer from \(from).")
        refreshSuggestion()
      }
      return posted
    } catch {
      lastError = "Could not book the incoming transfer."
      return false
    }
  }

  /// Send a stablecoin out, as the other half of the cross-app demo.
  func sendExternalTransfer(asset: Asset, amount: Money, to: String) -> Bool {
    let fee = Money(minorUnits: 120_000, currency: asset)
    let total = amount + fee
    guard total <= ledger.balance(ofAsset: asset) else {
      lastError = "Not enough \(asset.code)."
      return false
    }
    let key = "xfer-out-\(asset.code)-\(amount.minorUnits)-\(Int(Date().timeIntervalSince1970))"
    do {
      let posted = try ledger.post(
        JournalEntry(
          idempotencyKey: key,
          date: Date(),
          memo: "Sent \(amount.display) to \(to)",
          references: EntryReferences(instruction: "Outbound \(asset.code) transfer"),
          postings: [
            Posting(accountId: Ledger.accountId(for: asset),
                    amount: Money(minorUnits: -total.minorUnits, currency: asset)),
            Posting(accountId: "fees.\(asset.code.lowercased())", amount: fee),
            Posting(accountId: "world.\(asset.code.lowercased())", amount: amount),
          ]
        )
      )
      if posted {
        record(.payment, "Sent \(amount.display)", "Outbound \(asset.code) transfer to \(to). Fee \(fee.display).")
        refreshSuggestion()
      }
      return posted
    } catch {
      lastError = "The ledger rejected that transfer."
      return false
    }
  }

  // MARK: Cross-app relay

  /// This app's name on the relay, so it never receives its own transfers.
  var appName: String { CurrentBrand.theme.productName }

  /// Start reconciling with the durable relay. Harmless if the proxy is not
  /// running: a reconcile simply returns nothing.
  func startRelayPolling() {
    guard relayTask == nil else { return }
    relayTask = Task { [weak self] in
      // Reconcile from zero on purpose. The ledger is durable, and a transfer
      // sent while this app was closed is still a transfer this app should
      // receive. Local postings are keyed by the relay's transfer id, so
      // re-reading the whole history is exact and never books twice.
      await self?.reconcileRelay()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await self?.reconcileRelay()
      }
    }
  }

  func stopRelayPolling() {
    relayTask?.cancel()
    relayTask = nil
  }

  /// Re-read the authoritative ledger and apply anything this app has not
  /// already applied. Both directions: an outflow this app sent (so its local
  /// balance matches after a restart) and an inflow from the other app.
  func reconcileRelay() async {
    let transfers = await relay.transfers(identity: appName, since: 0)
    guard !transfers.isEmpty else { return }
    var applied = 0
    var received: [String] = []
    for transfer in transfers {
      if transfer.to == appName {
        if applyRelayTransfer(transfer, direction: .inbound) {
          applied += 1
          lastReceivedFrom = transfer.from
          if let asset = transfer.asset {
            let amount = Money(minorUnits: transfer.amountMinor, currency: asset)
            received.append("\(amount.display) from \(transfer.from)")
          }
        }
      } else if transfer.from == appName {
        if applyRelayTransfer(transfer, direction: .outbound) { applied += 1 }
      }
    }
    if applied > 0 {
      // Name what actually arrived when something did, so "received" is visible
      // on the home screen rather than only inferred from a changed balance.
      if let first = received.first {
        relayNotice =
          received.count == 1
          ? "Received \(first)."
          : "Received \(received.count) transfers, including \(first)."
      } else {
        relayNotice =
          "Updated your balances for \(applied) transfer\(applied == 1 ? "" : "s")."
      }
      relayNoticeAt = Date()
      refreshSuggestion()
    }
  }

  /// Book one relay transfer into the local ledger, exactly once, keyed by the
  /// relay's own transfer id.
  @discardableResult
  func applyRelayTransfer(_ transfer: RelayTransfer, direction: RelayDirection) -> Bool {
    guard let asset = transfer.asset, transfer.amountMinor > 0 else { return false }
    let amount = Money(minorUnits: transfer.amountMinor, currency: asset)
    let key = direction == .inbound ? "relay-in-\(transfer.id)" : "relay-out-\(transfer.id)"
    let wallet = Ledger.accountId(for: asset)
    let world = "world.\(asset.code.lowercased())"
    let counterparty = direction == .inbound ? transfer.from : transfer.to

    do {
      let posted = try ledger.post(
        JournalEntry(
          idempotencyKey: key,
          date: Date(),
          memo: direction == .inbound
            ? "Received from \(counterparty)" : "Sent to \(counterparty)",
          references: EntryReferences(
            instruction: "Mira · transfer between apps",
            providerReference: transfer.id),
          postings: direction == .inbound
            ? [
              Posting(
                accountId: world,
                amount: Money(minorUnits: -amount.minorUnits, currency: asset)),
              Posting(accountId: wallet, amount: amount),
            ]
            : [
              Posting(
                accountId: wallet,
                amount: Money(minorUnits: -amount.minorUnits, currency: asset)),
              Posting(accountId: world, amount: amount),
            ]
        )
      )
      if posted {
        record(
          .payment,
          direction == .inbound ? "Received \(amount.display)" : "Sent \(amount.display)",
          "\(direction == .inbound ? "Received from" : "Sent to") \(counterparty) · \(transfer.id).")
        // A settled inbound payment is a rule trigger: the money arrived from a
        // named payer, and any approved rule on that payer is evaluated now.
        if direction == .inbound {
          evaluateRules(trigger: .paymentReceived, subject: counterparty, amount: amount)
        }
      }
      return posted
    } catch {
      lastError = "The ledger rejected a relay transfer: \(error)"
      return false
    }
  }

  /// The manual demo control: send to the other app through the durable relay.
  @discardableResult
  func sendToOtherApp(asset: Asset, amount: Money) async -> Bool {
    let outcome = await relay.transfer(
      idempotencyKey: "manual-xfer-\(UUID().uuidString)",
      from: appName, to: otherAppName, asset: asset, amount: amount,
      note: "From \(appName)")
    switch outcome {
    case .settled(let transfer), .duplicate(let transfer):
      _ = applyRelayTransfer(transfer, direction: .outbound)
      return true
    case .rejected, .unreachable:
      lastError = outcome.userMessage
      return false
    }
  }

  /// Kept for older surfaces: publish a transfer through the durable relay.
  func publishTransfer(asset: Asset, amount: Money, note: String) async {
    _ = await relay.transfer(
      idempotencyKey: "publish-\(UUID().uuidString)",
      from: appName, to: otherAppName, asset: asset, amount: amount, note: note)
  }

  /// Records a swap that has already been posted to the ledger by the UI.
  ///
  /// The posting is the fact; this only writes the history entry, so a swap
  /// cannot be double-counted by being both posted and recorded.
  func recordSwap(_ quote: SwapQuote) {
    record(
      .payment,
      "Swapped \(quote.fromAmount.display) to \(quote.totalDebit.display.hasPrefix("-") ? "" : "")",
      "\(quote.from.code) to \(quote.to.code) at \(quote.rateLabel). Received \(quote.toAmount.display)."
    )
    refreshSuggestion()
  }

  /// Drop the current proposal, keeping the conversation.
  func dismissProposal() {
    lastAgentReply = nil
  }

  /// Clear the turns of the active conversation, keeping the thread itself.
  /// (Starting a fresh conversation is `newConversation()`; it archives this one.)
  func clearConversation() {
    conversation.removeAll()
    agentSessionId = nil
    lastAgentReply = nil
    lastAgentError = nil
    pendingTransfer = nil
    transferProposalStates.removeAll()
    lastOrchestration = nil
    persistCurrentThread()
    record(.data, "Conversation cleared", "This thread's transcript was emptied.")
  }

  // MARK: Chips
  //
  // Chips are the answer's own next moves. They belong to the last turn of the
  // flow that owns them — the split's, the fees card's, the task's — not to
  // whichever turn happens to be newest. A flow that has moved on (the parcel
  // was delivered, the ask was answered) shows its newer turn's chips instead,
  // so a suggestion whose action no longer applies is never resurrected.

  /// The turns that should render their chips. A turn with no flow is its own
  /// flow: an answer that exists once exists once.
  static func chipTurnIds(in turns: [ConversationTurn]) -> Set<UUID> {
    var lastByFlow: [String: UUID] = [:]
    for turn in turns where turn.role == .mira {
      lastByFlow[Self.flowKey(of: turn)] = turn.id
    }
    return Set(
      turns.compactMap { turn in
        guard turn.role == .mira else { return nil }
        guard lastByFlow[Self.flowKey(of: turn)] == turn.id else { return nil }
        return turn.chips.isEmpty ? nil : turn.id
      })
  }

  private static func flowKey(of turn: ConversationTurn) -> String {
    if let flow = turn.flow, !flow.isEmpty { return flow }
    if turn.action?.kind == .agentTask, let id = turn.action?.taskId, !id.isEmpty {
      return "task:\(id)"
    }
    return "turn:\(turn.id.uuidString)"
  }

  /// The turns whose chips are live, for the view.
  var chipTurnIds: Set<UUID> { Self.chipTurnIds(in: conversation) }

  /// Remove a chip whose action has just been performed, wherever it is still
  /// sitting in the transcript. A suggestion that is already fulfilled is not a
  /// suggestion; this is what keeps "Cancel Notion Plus" from being offered
  /// again after Notion Plus was cancelled.
  private func dropChips(matching predicate: (String) -> Bool) {
    var changed = false
    for index in conversation.indices where conversation[index].chips.contains(where: predicate) {
      conversation[index] = conversation[index].with(
        chips: conversation[index].chips.filter { !predicate($0) })
      changed = true
    }
    if changed { persistCurrentThread() }
  }

  // MARK: Flows the app owns

  /// A Mira turn with the chips (and card) the moment calls for.
  private func appendMira(
    _ text: String,
    chips: [String] = [],
    card: CardMock? = nil,
    cardCaption: String? = nil,
    receipt: ReceiptSpec? = nil,
    isError: Bool = false,
    flow: String? = nil
  ) {
    appendTurn(
      ConversationTurn(
        role: .mira, text: text, specialist: activeSpecialist, action: nil,
        replySource: "deterministic", isError: isError,
        chips: chips, flow: flow, card: card, cardCaption: cardCaption, receipt: receipt))
  }

  /// A swap the person was shown, waiting for their yes. Executes on the exact
  /// quote; an expired quote is re-priced, never silently changed.
  private func handlePendingSwap(_ text: String) async -> Bool {
    guard let quote = pendingSwap else { return false }

    if StandaloneAgent.isNegative(text) {
      pendingSwap = nil
      pendingConversion = nil
      appendMira(
        "Nothing moved — I've set that quote aside.", chips: ["Show my balances"], flow: "swap")
      return true
    }
    guard StandaloneAgent.isAffirmative(text) else {
      // Anything else is a new subject: the quote stops applying.
      pendingSwap = nil
      pendingConversion = nil
      return false
    }
    if quote.isExpired(at: Date()) {
      guard let fresh = try? SimulatedSwapProvider(table: RateTable.current).quote(
        from: quote.from, to: quote.to, amount: quote.fromAmount)
      else {
        pendingSwap = nil
        appendMira("That quote expired and I could not price a new one just now.")
        return true
      }
      pendingSwap = fresh
      appendMira(
        "That quote was a few minutes old, so here it is at today's rate: \(fresh.rateLabel), fee \(fresh.fee.display), all-in \(fresh.totalDebit.display). Swap it?",
        chips: ["Swap it", "Cancel"],
        flow: "swap")
      return true
    }

    do {
      let posted = try ledger.postSwap(
        quote,
        idempotencyKey: "chat-swap-\(quote.id.uuidString)",
        memo: "Swap \(quote.from.code) to \(quote.to.code)",
        at: Date())
      guard posted else {
        pendingSwap = nil
        appendMira("That swap was already recorded — nothing was double-counted.")
        return true
      }
      recordSwap(quote)
      pendingSwap = nil
      pendingConversion = nil
      let slip = ReceiptSpec.swap(quote, reference: String(quote.id.uuidString.prefix(8)).uppercased())
      appendMira(
        "Done — \(quote.toAmount.display) is in your balance.",
        chips: ["Show my balances"],
        receipt: slip,
        flow: "swap")
    } catch {
      pendingSwap = nil
      appendMira("The ledger rejected that swap, so nothing moved.", isError: true)
    }
    return true
  }

  /// A rate the person stated and asked the assistant to apply — "use 1 USD =
  /// 6.00 BRL". Refused deterministically, in the fixed words, and the quote
  /// they were shown (if any) is set aside: the only bookable rate is one the
  /// app quoted.
  private func handleRateBookingIntent(_ text: String) -> Bool {
    guard StandaloneAgent.asksToBookAForeignRate(text) else { return false }
    pendingConversion = nil
    pendingSwap = nil
    appendMira(StandaloneAgent.rateBookingRefusal, flow: "rate-guard")
    record(.note, "Rate refused", "A rate the app did not quote was never applied.")
    return true
  }

  /// A question about the build itself — what moves money, what is simulated,
  /// what needs approval, what is refused — answered from the capability
  /// document. No network, no model, and never a transfer prompt.
  private func handleCapabilityIntent(_ text: String) -> Bool {
    guard CapabilityDocument.asksAboutThisBuild(text) else { return false }
    appendMira(CapabilityDocument.answer, flow: "capability")
    record(.note, "Answered from this device", "capability document")
    return true
  }

  /// A corridor this build does not price: the answer names the currency it
  /// cannot quote and the ones it can. Never a transfer prompt, never a task.
  private func handleCorridorIntent(_ text: String) -> Bool {
    guard let answer = StandaloneAgent.corridorAnswer(for: text) else { return false }
    appendMira(answer, flow: "corridor")
    record(.note, "Answered from this device", "corridor table")
    return true
  }

  /// The money desk: twelve things a bank can do that mostly are not done,
  /// because each needs an agent rather than a form. Every branch here is
  /// deterministic; the ones that end in an action end in one confirmation.
  private func handleMoneyDeskIntent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    func has(_ words: [String]) -> Bool { words.contains { lowered.contains($0) } }

    // 12 · A charge the app does not recognise, reviewed in conversation when
    // it is asked for. The natural ways to ask all land here, and the answer is
    // the same one the card always gave, with the same chips.
    if has([
      "is this yours", "unknown charge", "do not recognise", "don't recognise", "recognise this",
      "recognize this", "anything suspicious", "review my card", "check my card",
      "anything i should check",
    ]) {
      return surfaceFlaggedCharge()
    }
    if lowered.contains("it's mine") || lowered.contains("its mine") {
      if let flagged = localDirectory.flaggedCharges.first {
        localDirectory.resolveFlaggedCharge(flagged.id)
        appendMira(
          "Noted — \(flagged.merchant) is fine.", chips: ["Show my balances"],
          flow: "flagged-charge")
        return true
      }
    }
    if lowered.contains("no — block it") || lowered.contains("no - block it") || lowered.contains("block it") {
      if let flagged = localDirectory.flaggedCharges.first {
        localDirectory.resolveFlaggedCharge(flagged.id)
        let card = mainCard.last4
        localDirectory.blockMerchant(flagged.merchant, on: card)
        appendMira(
          "Blocked \(flagged.merchant) on the card ending \(card). The next charge will be declined.",
          chips: ["Show my balances"],
          flow: "flagged-charge")
        return true
      }
    }

    // 11 · Credit-building autopilot.
    if has(["utilisation", "utilization", "statement", "credit card", "credit limit"]) {
      let balance = Money(minorUnits: localDirectory.creditBalanceMinor, currency: .brl)
      let limit = Money(minorUnits: localDirectory.creditLimitMinor, currency: .brl)
      let instruction = CreditAutopilot.instruction(
        balance: balance, limit: limit, statementDay: localDirectory.statementDay)
      appendMira(
        CreditAutopilot.lead(instruction),
        chips: CreditAutopilot.chips(amount: instruction.amount),
        receipt: ReceiptSpec.brief(
          badge: "CREDIT", symbol: "creditcard", title: "Utilisation plan",
          lines: [
            ReceiptLine(label: "Balance", value: balance.display),
            ReceiptLine(label: "Limit", value: limit.display),
            ReceiptLine(label: "Pay by", value: instruction.payBy),
          ],
          total: ReceiptLine(
            label: "Pay",
            value: instruction.amount.minorUnits == 0 ? "Nothing now" : instruction.amount.display),
          footnote: instruction.note),
        flow: "credit")
      return true
    }

    // 10 · Split and settle.
    //
    // A split that already exists is read back from the app's own record: the
    // card and the chip must describe the same fact.
    if has(["show the splits", "show splits", "my splits", "what do i owe", "who owes"]) {
      guard let split = localDirectory.splits.last else {
        appendMira(
          "I don't have any splits on record yet — nothing has actually been set up. Tell me the total and who shares it, and I'll lay out who owes what; nothing goes out until you approve it.",
          flow: "split")
        return true
      }
      let open = split.shares.filter { !$0.settled }
      appendMira(
        Splits.summary(for: split),
        chips: open.isEmpty ? ["Show my balances"] : Splits.chips(for: split),
        receipt: Splits.receipt(for: split),
        flow: "split")
      return true
    }
    if has(["split ", "split the", "divide"]) {
      // A split is often said as a bare number: "split 240 with Ana".
      let bare = text.range(of: "\\d+(?:[.,]\\d{1,2})?", options: .regularExpression)
        .flatMap { Decimal(string: text[$0].replacingOccurrences(of: ",", with: ".")) }
      let amount = CheckoutFlow.amount(from: text)
        ?? bare.map { Money(majorUnits: $0, currency: .brl) }
        ?? Money(minorUnits: 0, currency: .brl)
      let people = Splits.people(in: text)
      // Never guess shares. Fewer than two named people is a question, not a
      // split: the person is in it or not, and the app cannot know which.
      guard amount.minorUnits > 0 else { return false }
      guard people.count >= 2 else {
        appendMira(
          "Who is sharing the \(amount.display)? Name at least two people and I'll lay out who owes what — nothing goes out until you approve it.",
          chips: [],
          flow: "split")
        return true
      }
      let split = Splits.even(amount, among: people)
      localDirectory.saveSplit(split)
      appendMira(
        Splits.sentence(for: split),
        chips: Splits.chips(for: split),
        receipt: Splits.receipt(for: split),
        flow: "split")
      return true
    }
    if has(["split paid", "paid me", "settle the split", "settled"]) {
      guard let split = localDirectory.splits.last else { return false }
      // A chip names one person ("Ana paid me"); settle exactly that share. A
      // general "settle the split" still settles everyone.
      let named = split.shares.first {
        !$0.settled && text.localizedCaseInsensitiveContains($0.person)
      }
      let toSettle = named.map { [$0] } ?? split.shares.filter { !$0.settled }
      for share in toSettle {
        localDirectory.settleSplitShare(split.id, person: share.person)
      }
      let refreshed = localDirectory.splits.last ?? split
      let line =
        named.map { "Noted — \($0.person) is square. \(refreshed.outstanding.display) still outstanding." }
        ?? "Settled — \(split.total.display), everyone square."
      appendMira(
        line,
        chips: Splits.chips(for: refreshed),
        receipt: Splits.receipt(for: refreshed),
        flow: "split")
      return true
    }

    // 6 · Income smoothing.
    if has(["got paid", "i was paid", "received a payment", "freelance"]) {
      guard let amount = CheckoutFlow.amount(from: text) else {
        appendMira("How much came in? I'll carve it the way it has to be carved.")
        return true
      }
      let split = IncomeSmoothing.split(received: amount)
      appendMira(
        "\(amount.display) in: \(split.tax.display) tax, \(split.buffer.display) buffer, \(split.spendable.display) spendable.",
        chips: ["Put it away", "Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "INCOME", symbol: "arrow.down.circle", title: "Where the money goes",
          lines: [
            ReceiptLine(label: "Tax (15%)", value: split.tax.display),
            ReceiptLine(label: "Buffer (20%)", value: split.buffer.display),
          ],
          total: ReceiptLine(label: "Spendable", value: split.spendable.display),
          footnote: split.note),
        flow: "income")
      return true
    }

    // 6b · The income plan: a month's income arranged as reserve, confirmed
    // bills and living costs, flexible spending and a goal — computed from the
    // records the app holds, editable row by row with a change-preview, and
    // approved as a recorded allocation. It moves nothing.
    if has([
      "income plan", "monthly plan", "monthly allocation", "plan my month", "plan the month",
      "where does my month go", "allocate my income",
    ]) {
      if has(["approve"]) {
        guard localDirectory.incomePlan != nil else {
          appendMira(
            "There is no income plan yet — say \"plan my month with USD 4,000\" and I'll lay one out from your records.",
            flow: "income-plan")
          return true
        }
        localDirectory.approveIncomePlan()
        guard let saved = localDirectory.incomePlan else { return true }
        appendMira(
          "Recorded — \(saved.income.display) a month: \(saved.reserve.display) reserve, "
            + "\(saved.bills.display) bills and living costs, \(saved.flexible.display) flexible, "
            + "\(saved.goal.display) to \(saved.goalName ?? "the goal"). Nothing moved; these are earmarks.",
          chips: ["Show my balances"],
          receipt: ReceiptSpec.incomePlan(saved),
          flow: "income-plan")
        record(.plan, "Income plan approved", saved.statusLine)
        return true
      }
      if let stated = CheckoutFlow.amount(from: text) ?? bareAmount(text, currency: plan.total.currency) {
        let proposal = IncomeSmoothing.monthlyProposal(
          income: stated,
          bills: localDirectory.bills,
          subscriptions: localDirectory.subscriptions,
          weeklyBudget: plan.weeklyBudgetMoney,
          goals: localDirectory.goals)
        localDirectory.saveIncomePlan(proposal)
        let excluded = proposal.excludedRecords.isEmpty
          ? ""
          : " Not counted here: \(proposal.excludedRecords.joined(separator: ", ")) — another currency is never summed across a rate I do not own."
        appendMira(
          "Here is \(stated.display) a month, arranged the way a month actually goes. \(proposal.statusLine)\(excluded) Edit any row and I'll show what moves; nothing is recorded until you approve it.",
          chips: ["Approve the income plan"],
          receipt: ReceiptSpec.incomePlan(proposal),
          flow: "income-plan")
        return true
      }
      if let existing = localDirectory.incomePlan {
        appendMira(
          existing.isApproved
            ? "Your income plan: \(existing.statusLine)"
            : "The proposed month: \(existing.statusLine) Approve it, or edit a row and I'll show what moves.",
          chips: existing.isApproved ? ["Set the reserve to …"] : ["Approve the income plan"],
          receipt: ReceiptSpec.incomePlan(existing),
          flow: "income-plan")
        return true
      }
      appendMira(
        "How much comes in this month? Say \"plan my month with USD 4,000\" and I'll lay it out from your bills, subscriptions, week budget and goals.",
        flow: "income-plan")
      return true
    }

    // An edit to the income plan: the preview says what moves and what stays.
    if let allocation = localDirectory.incomePlan,
      let edit = incomePlanEdit(in: text, allocation: allocation)
    {
      let preview = allocation.preview(edit.row, to: edit.value)
      localDirectory.saveIncomePlan(preview.after)
      appendMira(
        preview.line,
        chips: ["Approve the income plan"],
        receipt: ReceiptSpec.incomePlan(preview.after),
        flow: "income-plan")
      return true
    }

    // 5 · Idle cash, with liquidity rules.
    if has(["put away", "put aside", "set it aside", "idle", "sweep", "safe to put"]) {
      let snapshot = standaloneSnapshot()
      let available = Money(majorUnits: Decimal(string: snapshot.available.replacingOccurrences(of: ",", with: "")) ?? 0, currency: .usd)
      let subs = Subscriptions.savings(localDirectory.subscriptions)
      let bills = localDirectory.billsByCurrency.first?.total ?? Money(minorUnits: 0, currency: .brl)
      let plan = IdleCash.plan(
        available: available,
        billsDue: bills,
        subscriptionsDue: subs?.monthly ?? Money(minorUnits: 0, currency: .brl),
        weekBudget: Money(majorUnits: Decimal(string: snapshot.weekLeft.replacingOccurrences(of: ",", with: "")) ?? 0, currency: .usd),
        buffer: Money(majorUnits: 100, currency: .usd))
      appendMira(
        "\(plan.safeToSweep.display) is safe to put away.",
        chips: ["Put it away", "Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "IDLE CASH", symbol: "banknote", title: "\(plan.safeToSweep.display) safe to sweep",
          subtitle: "What is not already promised",
          lines: [
            ReceiptLine(label: "Available", value: plan.available.display),
            ReceiptLine(label: "Bills due", value: plan.billsDue.display),
            ReceiptLine(label: "Subscriptions", value: plan.subscriptionsDue.display),
            ReceiptLine(label: "This week", value: plan.weekBudget.display),
            ReceiptLine(label: "Buffer kept", value: plan.buffer.display),
          ],
          total: ReceiptLine(label: "Safe to put away", value: plan.safeToSweep.display),
          footnote: plan.reason),
        flow: "idle-cash")
      return true
    }
    if lowered == "put it away" {
      appendMira(
        "Prepared — approving it in Plan moves \(standaloneSnapshot().weekLeft) aside and the reserve updates.",
        chips: ["Show my balances"],
        flow: "idle-cash")
      return true
    }

    // 4 · Bill negotiation at renewal.
    if has(["negotiate", "renewal", "contract", "they raised"]) {
      guard let bill = localDirectory.negotiableBills.first else {
        appendMira(
          "I don't have a contract or renewal on record yet. Add the bill and its renewal date, and I can prepare an ask to compare.",
          flow: "negotiation")
        return true
      }
      let ask = Negotiation.prepare(bill)
      pendingNegotiation = ask
      appendMira(
        "\(bill.name) renews \(ask.deadline). \(bill.competitor) is \(bill.competitorMonthly.display) a month — I prepared the ask, worth \(ask.yearlySaving.display) a year. The draft is below.",
        chips: ["They said yes", "They said no"],
        receipt: ReceiptSpec.negotiation(ask),
        flow: "negotiation")
      return true
    }
    if has(["they said yes", "they said no"]) {
      let yes = lowered.contains("yes")
      let ask = pendingNegotiation
      pendingNegotiation = nil
      appendMira(
        Negotiation.outcome(ask, accepted: yes),
        chips: ["Show all subscriptions"],
        flow: "negotiation")
      return true
    }

    // 3 · Fee radar.
    if has(["fee", "fees"]) {
      let tier = Capacity.tier(
        for: Capacity.facts(
          accountOpenedAt: localDirectory.accountOpenedAt,
          goals: localDirectory.goals,
          blockedCharges: localDirectory.blockedChargeCount,
          balance: clearedUSD)
      ).tier
      let findings = FeeRadar.findings(localDirectory.feeEvents, fxFeeLabel: tier.fxFeeLabel)
      guard !findings.isEmpty else { return false }
      let totals = FeeRadar.totalsByCurrency(findings)
      appendMira(
        FeeRadar.answer(findings: findings),
        chips: FeeRadar.chips,
        receipt: ReceiptSpec.brief(
          badge: "FEES", symbol: "percent",
          title: totals.map(\.display).joined(separator: " · "),
          subtitle: "Three months, grouped by currency",
          lines: findings.map { ReceiptLine(label: $0.kind.label, value: "\($0.total.display) · \($0.count)x") },
          total: totals.count == 1 ? totals.first.map { ReceiptLine(label: "Total", value: $0.display) } : nil,
          footnote: findings.map(\.advice).joined(separator: " ")),
        flow: "fees")
      return true
    }

    // 2 · Zombies and overlaps.
    if has(["unused", "zombie", "not using", "wasting", "overlap", "still paying"]) {
      let findings = Zombies.findings(localDirectory.subscriptions)
      guard !findings.isEmpty else {
        appendMira("Nothing looks dead — every subscription has been used recently.")
        return true
      }
      let saving = Zombies.yearlySaving(findings)
      appendMira(
        Zombies.answer(findings, saving: saving),
        chips: Zombies.chips(findings),
        receipt: ReceiptSpec.brief(
          badge: "ZOMBIES", symbol: "moon.zzz", title: Zombies.cardTitle(findings),
          subtitle: "Unused, duplicated, or already included",
          lines: findings.map {
            ReceiptLine(
              label: $0.subscription.name,
              value: "\($0.subscription.monthly.display) · \($0.reason.line)",
              service: $0.subscription.name)
          },
          total: ReceiptLine(label: "A year", value: saving?.display ?? "—"),
          footnote: "Cancelling blocks the merchant at the card."),
        flow: "zombies")
      return true
    }

    // 1 · Price-drop retro-claims.
    if has(["price claim", "price match", "price fell", "price dropped", "retro"]) {
      let open = PriceClaims.open(localDirectory.priceClaims)
      guard !open.isEmpty else {
        appendMira(
          "No open windows. When you buy something, I keep the receipt and watch the price for 30 days — say the new price and I'll do the rest.")
        return true
      }
      guard let claim = open.first else { return false }
      appendMira(
        "\(claim.item): paid \(claim.paid.display), \(claim.daysLeft()) days left in the window. Tell me the price you see now and I'll prepare the claim.",
        chips: [],
        flow: "price-claim")
      return true
    }
    if has(["file it"]) {
      // A prepared price claim files against the store; a prepared case pack
      // files against the card network. Both were shown to the person first.
      if var claim = localDirectory.priceClaims.last(where: { $0.stage == .claimPrepared }) {
        let reference = "PM-\(Int.random(in: 10_000...99_999))"
        claim.stage = .filed
        claim.reference = reference
        localDirectory.savePriceClaim(claim)
        scheduleReminderRefresh()
        appendMira(
          "Filed — \(claim.claim?.display ?? "") back on \(claim.item), reference \(reference). I'll tell you when the store answers.",
          chips: ["Show my balances"],
          flow: "price-claim")
        return true
      }
      if var caseFile = localDirectory.claimCases.last(where: { $0.stage == "prepared" }) {
        let reference = "D-\(Int.random(in: 10_000...99_999))"
        caseFile.stage = "filed"
        caseFile.reference = reference
        localDirectory.saveClaimCase(caseFile)
        appendMira(
          "Filed — \(caseFile.kind.label), reference \(reference). I'll tell you when the network answers.",
          chips: ["Show my balances"],
          flow: "claims")
        return true
      }
      return false
    }

    // 13 · Can I do this without breaking my plan? Three concrete scenarios —
    // buy now / buy later / change the goal — each with the plan rows it moves
    // and its assumptions stated, including any reliance on money that has not
    // arrived. Every figure is the plan's own.
    if has([
      "can i afford", "can i spend", "is it okay to spend", "without breaking my plan",
      "without breaking the plan", "can i do this without",
    ]) {
      guard let stated = CheckoutFlow.amount(from: text) ?? bareAmount(text, currency: plan.total.currency)
      else {
        appendMira("How much is it? I'll price it against this week's plan.", flow: "scenario")
        return true
      }
      let goal =
        localDirectory.goals.first { text.localizedCaseInsensitiveContains($0.name) }
        ?? localDirectory.goals.first
      var amount = stated
      var conversionNote: String?
      if stated.currency != plan.total.currency {
        guard let converted = Affordability.convert(stated, to: plan.total.currency) else {
          appendMira(
            "I cannot compare \(stated.display) with a \(plan.total.currency.code) plan without a rate I trust.",
            flow: "scenario")
          return true
        }
        amount = converted.money
        conversionNote = converted.assumption
      }
      guard var answer = Affordability.scenarios(
        amount: amount,
        plan: plan,
        goal: goal,
        pendingIncome: ledger.pendingUSD,
        weekIndex: currentWeekIndex)
      else {
        appendMira("I could not price that against the plan.", flow: "scenario")
        return true
      }
      if let conversionNote {
        for index in answer.scenarios.indices {
          answer.scenarios[index].assumptions.insert(conversionNote, at: 0)
        }
      }
      let fitting = answer.scenarios.first { $0.works }
      let effect = fitting?.effects.first.map { " \($0.line)." } ?? ""
      appendMira(
        answer.lead + " " + (fitting?.headline ?? "None of the three works without changing the plan.")
          + effect,
        receipt: answer.document,
        flow: "scenario")
      return true
    }

    // 9a · The piggy banks. Opening the screen is an app action, not a model
    // answer: the turn says what is in there and the shell opens the carousel.
    if has(["piggy bank", "piggy banks", "my dreams", "savings goals", "dreams in progress"]) {
      let goals = localDirectory.goals
      guard let closest = goals.max(by: { progress(of: $0) < progress(of: $1) }) else {
        appendMira(
          "No piggy banks yet — tell me what you are saving for and I'll start one.",
          flow: "goals")
        return true
      }
      requestedRoute = .piggyBanks
      appendMira(
        "\(goals.count) piggy bank\(goals.count == 1 ? "" : "s"). The closest to its target is "
          + "\(closest.name): \(closest.saved.display) of \(closest.target.display). Opening them for you.",
        chips: ["Show my balances"],
        flow: "goals")
      return true
    }

    // 9 · Goals, with guards.
    if has(["goal", "travel fund", "protected", "keep the fund"]) {
      guard let goal = localDirectory.goals.first else { return false }
      appendMira(
        "\(goal.name): \(goal.saved.display) of \(goal.target.display) — \(goal.remaining.display) to go, and it is protected.",
        chips: ["Open my piggy banks", "Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "GOAL", symbol: "flag.checkered", title: goal.name, subtitle: goal.protected ? "Protected" : "Open",
          lines: [
            ReceiptLine(label: "Saved", value: goal.saved.display),
            ReceiptLine(label: "Target", value: goal.target.display),
          ],
          total: ReceiptLine(label: "To go", value: goal.remaining.display),
          footnote: "A purchase that would eat into it asks first."),
        flow: "goals")
      return true
    }

    // 8 · Agent budgets.
    if has(["agent", "sub-agent", "budget for", "limit for"]) {
      guard let budget = localDirectory.agentBudgets.first else {
        appendMira("No agent has a budget yet — say \"give my shopping agent R$ 300 a month\".")
        return true
      }
      appendMira(
        "\(budget.agent): \(budget.spent.display) of \(budget.limit.display) used, \(budget.remaining.display) left.",
        chips: ["Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "AGENTS", symbol: "cpu", title: budget.agent, subtitle: "Monthly limit",
          lines: [ReceiptLine(label: "Spent", value: budget.spent.display, icon: "creditcard")]
            + budget.receipts.suffix(3).map { ReceiptLine(label: "Receipt", value: $0, icon: "doc.text") },
          total: ReceiptLine(label: "Left", value: budget.remaining.display),
          footnote: "An agent cannot spend past its limit; it asks you instead."),
        flow: "agent-budget")
      return true
    }

    // 7 · Claims, prepared for the person.
    if has(["delayed", "damaged", "refund", "compensation"]) {
      let kind: ClaimCase.Kind = lowered.contains("refund")
        ? .refundOverdue
        : lowered.contains("damaged") ? .damagedDelivery : .flightDelay
      let caseFile = Claims.prepare(kind, subject: text.trimmingCharacters(in: .whitespacesAndNewlines))
      localDirectory.saveClaimCase(caseFile)
      appendMira(
        "\(kind.label) — I prepared the pack: \(caseFile.documents.joined(separator: ", ")).",
        chips: ["File it", "Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "CLAIM", symbol: "doc.badge.clock", title: kind.label, subtitle: caseFile.subject,
          lines: caseFile.documents.map {
            ReceiptLine(label: "Document", value: $0, icon: "doc.text")
          },
          total: caseFile.amountMinor.map { ReceiptLine(label: "Claiming", value: Money(minorUnits: $0, currency: caseFile.currency).display) },
          footnote: "Nothing is filed until you say so."),
        flow: "claims")
      return true
    }

    return false
  }

  // MARK: The income plan helpers

  /// How far along a goal is. A goal with no target yet reads as zero rather
  /// than dividing by nothing.
  private func progress(of goal: Goal) -> Double {
    guard goal.targetMinor > 0 else { return 0 }
    return Double(goal.savedMinor) / Double(goal.targetMinor)
  }

  /// A bare number in the message, read in the plan's own currency. Used only
  /// where the app states which currency it assumed. Handles both `1,200.50`
  /// and `1.200,50` by whichever separator comes last, the same rule the
  /// proxy's amount parser uses.
  private func bareAmount(_ text: String, currency: Asset) -> Money? {
    guard
      let match = text.range(
        of: "\\d{1,3}(?:[.,]\\d{3})+(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d{1,2})?",
        options: .regularExpression)
    else { return nil }
    let raw = String(text[match])
    let lastComma = raw.lastIndex(of: ",")
    let lastDot = raw.lastIndex(of: ".")
    var normalised = raw
    if let comma = lastComma, let dot = lastDot {
      normalised =
        comma > dot
        ? raw.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        : raw.replacingOccurrences(of: ",", with: "")
    } else if let comma = lastComma {
      let after = raw[raw.index(after: comma)...]
      normalised =
        after.count == 3
        ? raw.replacingOccurrences(of: ",", with: "")
        : raw.replacingOccurrences(of: ",", with: ".")
    }
    guard let value = Decimal(string: normalised), value > 0 else { return nil }
    return Money(majorUnits: value, currency: currency)
  }

  /// Which income-plan row a sentence edits, and to what. Only the flexible
  /// row is an absorber; a protected row is never silently dipped into.
  private func incomePlanEdit(
    in text: String, allocation: IncomeSmoothing.MonthlyAllocation
  ) -> (row: IncomeSmoothing.MonthlyAllocation.Row, value: Money)? {
    let lowered = text.lowercased()
    let row: IncomeSmoothing.MonthlyAllocation.Row?
    if lowered.contains("reserve") {
      row = .reserve
    } else if lowered.contains("bill") || lowered.contains("living") {
      row = .bills
    } else if lowered.contains("goal") {
      row = .goal
    } else if lowered.contains("flexib") || lowered.contains("spending") {
      row = .flexible
    } else {
      row = nil
    }
    guard let row else { return nil }
    guard let amount = CheckoutFlow.amount(from: text) ?? bareAmount(text, currency: allocation.currency)
    else { return nil }

    if lowered.contains("move ") {
      // Money moves through the flexible row. A sentence that names a
      // protected source ("from the reserve") is refused rather than obeyed
      // by a different route.
      if lowered.contains("from the reserve") || lowered.contains("from bills")
        || lowered.contains("from the goal")
      {
        return nil
      }
      return (row, allocation.amount(row) + amount)
    }
    return (row, amount)
  }

  // MARK: The rule contract
  //
  // "Every time X pays me, put 20% in the reserve" proposes a structured rule;
  // "make that a rule" approves the structure that was shown — never the
  // sentence. The app's own reader builds the contract, code validates it, the
  // mandate bounds it, and a commit still passes the same consent policy as
  // everything else. No confidence anywhere in the decision.

  private func handleRuleIntent(_ text: String) -> Bool {
    let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // One word on a rule action that was prepared and shown.
    if let pending = pendingRuleAction {
      if StandaloneAgent.isAffirmative(lowered) || lowered.contains("apply it") {
        applyPreparedRule(pending)
        return true
      }
      if StandaloneAgent.isNegative(lowered) || lowered.contains("not now") || lowered.contains("skip") {
        pendingRuleAction = nil
        appendMira(
          "Left it — the rule is still \(pending.rule.delegation.rawValue), and nothing was applied.",
          chips: ["Show the rule"], flow: "rule-run")
        return true
      }
    }

    // "make that a rule" approves the structured contract already shown.
    if lowered.contains("make that a rule") || lowered.contains("make it a rule")
      || lowered.contains("turn that into a rule")
    {
      guard let pending = pendingRule else {
        appendMira(
          "Tell me the rule first — \"every time Maria pays me, put 20% in the reserve\" — and I'll show you the structure to approve.",
          flow: "rule")
        return true
      }
      approveRule(pending)
      return true
    }

    if lowered.contains("approve the rule") || lowered.contains("approve it as a rule") {
      guard let pending = pendingRule else { return false }
      approveRule(pending)
      return true
    }

    if lowered.contains("not now") || lowered.contains("leave the rule") {
      guard let pending = pendingRule else { return false }
      pendingRule = nil
      appendMira("Set aside — nothing was approved.", chips: ["Show my balances"], flow: "rule")
      _ = pending
      return true
    }

    if lowered.contains("make it automatic") || lowered.contains("autopilot") {
      return makeRuleAutomatic(from: text)
    }

    if lowered.contains("pause the rule") || lowered.contains("stop the rule") {
      guard let rule = localDirectory.rules.last else {
        appendMira("There is no rule on file yet.", flow: "rule")
        return true
      }
      localDirectory.setRulePaused(rule.id, paused: true)
      appendMira(
        "Paused — nothing runs until you say \"resume the rule\".",
        chips: ["Resume the rule", "Show the rule"], flow: "rule")
      return true
    }

    if lowered.contains("resume the rule") || lowered.contains("start the rule again") {
      guard let rule = localDirectory.rules.last else {
        appendMira("There is no rule on file yet.", flow: "rule")
        return true
      }
      localDirectory.setRulePaused(rule.id, paused: false)
      appendMira(
        "Back on. \(RulesEngine.sentence(for: rule))",
        chips: ["Pause the rule"], flow: "rule")
      return true
    }

    if lowered.contains("show the rule") || lowered.contains("show my rules") {
      guard let rule = localDirectory.rules.last else {
        appendMira(
          "No rules yet. Say \"every time Maria pays me, put 20% in the reserve\" and I'll show you the structure.",
          flow: "rule")
        return true
      }
      appendMira(
        RulesEngine.sentence(for: rule),
        chips: rule.isApproved ? ["Pause the rule"] : ["Approve the rule", "Not now"],
        receipt: RulesEngine.document(for: rule),
        flow: "rule")
      return true
    }

    // A new proposal: the sentence names a standing event and a runnable action.
    if let proposal = RulesEngine.propose(from: text) {
      pendingRule = proposal
      appendMira(
        "Here is the rule I read: \(RulesEngine.sentence(for: proposal)) "
          + "Nothing runs until you approve this exact structure — not the sentence.",
        chips: ["Approve the rule", "Make it automatic", "Not now"],
        receipt: RulesEngine.document(for: proposal),
        flow: "rule")
      return true
    }

    // A standing-event sentence the reader could not turn into a contract: the
    // event or the action is missing, and the app says exactly which it needs
    // rather than letting a model invent one.
    if lowered.range(of: "every time|whenever", options: .regularExpression) != nil,
      lowered.contains("paid") || lowered.contains("pays me") || lowered.contains("charges")
    {
      appendMira(
        "I can make that a rule, but a rule needs a named event and an action this app can run. "
          + "Try \"every time Maria pays me, put 20% in the reserve\", or \"when Netflix charges, review my subscriptions\".",
        flow: "rule")
      return true
    }
    return false
  }

  private func approveRule(_ rule: RuleContract) {
    var approved = rule
    approved.isApproved = true
    approved.approvedAt = Date()
    localDirectory.saveRule(approved)
    pendingRule = nil
    appendMira(
      "Approved. \(RulesEngine.sentence(for: approved)) I'll act when it happens; say \"pause the rule\" to stop it.",
      chips: ["Pause the rule", "Show the rule"],
      receipt: RulesEngine.document(for: approved),
      flow: "rule")
    record(.preference, "Rule approved", RulesEngine.sentence(for: approved))
  }

  /// "Make it automatic up to X": the person bounds the mandate, code validates
  /// it, and only then may the rule stand at autopilot. Without a cap the app
  /// asks — a mandate that cannot be checked is not a mandate.
  private func makeRuleAutomatic(from text: String) -> Bool {
    guard var rule = pendingRule ?? localDirectory.rules.last else {
      appendMira(
        "Tell me the rule first — \"every time Maria pays me, put 20% in the reserve\" — then say \"make it automatic up to USD 250\".",
        flow: "rule")
      return true
    }
    guard let cap = CheckoutFlow.amount(from: text) ?? bareAmount(text, currency: plan.total.currency) else {
      appendMira(
        "Autopilot needs a cap. Say \"make it automatic up to USD 250\" and I'll bound it.",
        flow: "rule")
      return true
    }
    rule.delegation = .autopilot
    rule.mandate.amountCapMinor = cap.minorUnits
    rule.mandate.currencyCode = cap.currency.code
    rule.mandate.maxRuns = rule.mandate.maxRuns ?? 24
    rule.mandate.expiresAt =
      rule.mandate.expiresAt ?? Calendar.current.date(byAdding: .day, value: 90, to: Date())
    rule.isApproved = false
    rule.approvedAt = nil

    let errors = RulesEngine.validate(rule)
    guard errors.isEmpty else {
      appendMira("That rule does not validate: \(errors.joined(separator: "; ")).", flow: "rule")
      return true
    }
    pendingRule = rule
    let expiry = rule.mandate.expiresAt.map {
      DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
    } ?? "no expiry"
    appendMira(
      "Autopilot, bounded: up to \(cap.display), \(rule.mandate.maxRuns ?? 0) runs, expires \(expiry). "
        + "A commit inside it still passes the same consent policy as everything else. Approve the rule?",
      chips: ["Approve the rule", "Not now"],
      receipt: RulesEngine.document(for: rule),
      flow: "rule")
    return true
  }

  /// Evaluate every approved rule for one fired event. Composes and records;
  /// nothing here moves money, and a commit still goes through the app's own
  /// confirmation path.
  private func evaluateRules(
    trigger: RuleContract.TriggerKind, subject: String, amount: Money?, now: Date = Date()
  ) {
    let approved = localDirectory.rules.filter(\.isApproved)
    guard !approved.isEmpty else { return }
    for rule in approved {
      guard RulesEngine.matches(rule, trigger: trigger, subject: subject) else { continue }

      // Window-style triggers fire at most once a day per rule+subject.
      if trigger == .subscriptionCharge || trigger == .priceClaimWindow {
        let key = "\(rule.id.uuidString)|\(subject.lowercased())"
        if let last = ruleFiredAt[key], now.timeIntervalSince(last) < 20 * 3600 { continue }
        ruleFiredAt[key] = now
      }

      let facts = RuleFacts(
        planShortfall: !plan.status.isBalanced,
        incomeNotArrived: ledger.pendingUSD.minorUnits > 0,
        goalProtected: localDirectory.goals.contains { $0.protected && $0.savedMinor > 0 },
        paused: false)
      let decision = RulesEngine.decision(for: rule, amount: amount, now: now, facts: facts)
      switch decision.kind {
      case .refuse:
        continue
      case .ask:
        prepareRuleAction(rule, amount: amount, ask: true)
      case .prepare:
        prepareRuleAction(rule, amount: amount, ask: false)
      case .run:
        applyRule(rule, amount: amount)
      }
    }
  }

  /// The line a rule's action reads as, with the real figures.
  private func ruleLine(_ rule: RuleContract, amount: Money?) -> String {
    switch rule.action.verb {
    case "engine.reserve.share":
      if let share = reserveShare(of: rule, amount: amount) {
        return "put \(share.display) into the reserve"
      }
      return "put the money into the reserve"
    case "engine.income.smooth":
      return amount.map { "carve \($0.display) into tax, buffer and spendable" }
        ?? "carve the payment into tax, buffer and spendable"
    case "engine.subscriptions.review":
      return "review the recurring charges for waste"
    case "engine.price_claim.prepare":
      return "prepare the claim on \(rule.trigger.subject)"
    default:
      return RulesEngine.label(for: rule.action.verb).lowercased()
    }
  }

  private func reserveShare(of rule: RuleContract, amount: Money?) -> Money? {
    if let exact = rule.action.amountMinor {
      return Money(minorUnits: exact, currency: amount?.currency ?? .usd)
    }
    guard let amount else { return nil }
    if let percent = rule.action.sharePercent {
      let minor = NSDecimalNumber(
        decimal: Decimal(amount.minorUnits) * Decimal(percent) / 100
      ).int64Value
      return Money(minorUnits: minor, currency: amount.currency)
    }
    return amount
  }

  /// A rule that asks, or prepares: the action is shown and one word applies it.
  private func prepareRuleAction(_ rule: RuleContract, amount: Money?, ask: Bool) {
    let line = ruleLine(rule, amount: amount)
    pendingRuleAction = (rule, amount, line)
    appendMira(
      ask
        ? "Your rule asks first: \(line). Apply it?"
        : "Your rule prepared this: \(line). Apply it?",
      chips: ["Apply it", "Not now"],
      receipt: RulesEngine.document(for: rule),
      flow: "rule-run")
  }

  /// Autopilot inside the mandate. The engine actions that only earmark are
  /// applied; everything else is composed and handed to the app's own flow.
  private func applyRule(_ rule: RuleContract, amount: Money?) {
    switch rule.action.verb {
    case "engine.reserve.share":
      guard let share = reserveShare(of: rule, amount: amount) else { return }
      guard share.currency == plan.total.currency else {
        // The plan is kept in one currency. A share in another one is stated,
        // never added across a rate the app does not own.
        prepareRuleAction(rule, amount: amount, ask: false)
        return
      }
      plan.edit(.reserve, to: plan.reserveMoney.majorUnits + share.majorUnits, at: Date())
      plan.rebuildWeeks()
      localDirectory.noteRuleRun(rule.id)
      appendMira(
        "Rule ran — \(share.display) moved into the reserve. The reserve is now \(plan.reserveMoney.display).",
        chips: ["Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "RULE", symbol: "gearshape.2", title: "Reserve +\(share.display)",
          subtitle: RulesEngine.sentence(for: rule),
          lines: [ReceiptLine(label: "Into the reserve", value: share.display, icon: "lock")],
          total: ReceiptLine(label: "Reserve now", value: plan.reserveMoney.display),
          footnote: "An earmark inside your plan. Nothing left the account."),
        flow: "rule-run")
      record(.plan, "Rule ran", RulesEngine.sentence(for: rule))
    case "engine.income.smooth":
      guard let amount else { return }
      let split = IncomeSmoothing.split(received: amount)
      localDirectory.noteRuleRun(rule.id)
      appendMira(
        "Rule ran — \(split.note)",
        chips: ["Show my balances"],
        receipt: ReceiptSpec.brief(
          badge: "RULE", symbol: "arrow.down.circle", title: "Where the money goes",
          subtitle: RulesEngine.sentence(for: rule),
          lines: [
            ReceiptLine(label: "Tax (15%)", value: split.tax.display),
            ReceiptLine(label: "Buffer (20%)", value: split.buffer.display),
          ],
          total: ReceiptLine(label: "Spendable", value: split.spendable.display),
          footnote: split.note),
        flow: "rule-run")
      record(.plan, "Rule ran", RulesEngine.sentence(for: rule))
    case "engine.subscriptions.review":
      let findings = Zombies.findings(localDirectory.subscriptions)
      localDirectory.noteRuleRun(rule.id)
      appendMira(
        Zombies.answer(findings, saving: Zombies.yearlySaving(findings)),
        chips: Zombies.chips(findings),
        receipt: ReceiptSpec.brief(
          badge: "RULE", symbol: "moon.zzz", title: Zombies.cardTitle(findings),
          subtitle: RulesEngine.sentence(for: rule),
          lines: findings.map {
            ReceiptLine(
              label: $0.subscription.name,
              value: "\($0.subscription.monthly.display) · \($0.reason.line)",
              service: $0.subscription.name)
          },
          total: ReceiptLine(label: "A year", value: Zombies.yearlySaving(findings)?.display ?? "—"),
          footnote: "Nothing is cancelled until you say so."),
        flow: "rule-run")
      record(.plan, "Rule ran", RulesEngine.sentence(for: rule))
    case "engine.price_claim.prepare":
      guard let claim = PriceClaims.open(localDirectory.priceClaims).first(where: {
        $0.item.localizedCaseInsensitiveContains(rule.trigger.subject)
          || rule.trigger.subject.localizedCaseInsensitiveContains($0.item)
      }) else { return }
      localDirectory.noteRuleRun(rule.id)
      appendMira(
        "Rule ran — \(claim.item): paid \(claim.paid.display), \(claim.daysLeft()) days left. Tell me the price you see now and I'll prepare the claim.",
        chips: [], flow: "rule-run")
      record(.plan, "Rule ran", RulesEngine.sentence(for: rule))
    default:
      // A verb the app performs through its own controls: the rule composes
      // the action and hands it over rather than running unattended.
      prepareRuleAction(rule, amount: amount, ask: false)
    }
  }

  /// One word on a prepared rule action: the app's engine actions that only
  /// earmark are applied; a document is simply recorded.
  private func applyPreparedRule(_ pending: (rule: RuleContract, amount: Money?, line: String)) {
    pendingRuleAction = nil
    let rule = pending.rule
    switch rule.action.verb {
    case "engine.reserve.share":
      guard let share = reserveShare(of: rule, amount: pending.amount) else { return }
      guard share.currency == plan.total.currency else {
        appendMira(
          "The plan is kept in \(plan.total.currency.code), so I cannot add \(share.display) to the reserve without a conversion you approve.",
          chips: ["Show my balances"], flow: "rule-run")
        return
      }
      plan.edit(.reserve, to: plan.reserveMoney.majorUnits + share.majorUnits, at: Date())
      plan.rebuildWeeks()
      localDirectory.noteRuleRun(rule.id)
      appendMira(
        "Applied — \(share.display) moved into the reserve. The reserve is now \(plan.reserveMoney.display).",
        chips: ["Show my balances"], flow: "rule-run")
      record(.plan, "Rule applied", RulesEngine.sentence(for: rule))
    default:
      localDirectory.noteRuleRun(rule.id)
      appendMira(
        "Noted — \(pending.line). Nothing moved on its own.",
        chips: ["Show my balances"], flow: "rule-run")
    }
  }

  /// Offers, from both sides of the card: what the cardholder can earn and how
  /// it is going, and what the issuer is paying for and to whom.
  private func handleOffersIntent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    let asks = lowered.contains("cashback") || lowered.contains("cash back")
      || lowered.contains("offer") || lowered.contains("rewards") || lowered.contains("perks")
    guard asks else { return false }

    // "Did cashback land?" is answered by the landing line itself, and that
    // question is the only place pending cashback is credited. Asked for, never
    // announced.
    if surfaceCashbackCredits() { return true }

    let summary = Offers.summary(localDirectory.cashback)
    let issuer = Offers.issuerSummary(localDirectory.cashback)
    let lead =
      summary.map {
        "\($0.count) earn\($0.count == 1 ? "s" : "ings") this month: \($0.credited.display) credited, \($0.pending.display) pending."
      } ?? "No cashback yet this month."
    _ = issuer
    appendMira(
      lead + " The offers running now: " + Offers.running().prefix(3).map(\.title).joined(separator: "; ") + ".",
      chips: ["Show my balances"],
      receipt: ReceiptSpec.offers(localDirectory.cashback),
      flow: "offers")
    return true
  }

  /// The tier, from the app's own records: what the account has earned, what
  /// the tier lifts, and the one fact that would move it. Pure arithmetic on
  /// the same facts the document prints.
  private func handleCapacityIntent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    guard lowered.contains("tier") || lowered.contains("upgrade my account") else { return false }

    let facts = Capacity.facts(
      accountOpenedAt: localDirectory.accountOpenedAt,
      goals: localDirectory.goals,
      blockedCharges: localDirectory.blockedChargeCount,
      balance: clearedUSD)
    let assessment = Capacity.tier(for: facts)
    appendMira(
      "You are on \(assessment.tier.name) — \(assessment.tier.termsLine). \(assessment.nextLine)",
      chips: ["Show my balances"],
      receipt: ReceiptSpec.capacity(assessment),
      flow: "capacity")
    return true
  }

  /// A charge the app did not expect, reviewed in the conversation when it is
  /// asked for — "anything suspicious", "review my card", "check my card" —
  /// rather than by a fraud line at 3 a.m. It is its own turn with its own
  /// chips, so it can be answered on the spot, and it is never attached to a
  /// greeting. Answers whether there was anything to show.
  @discardableResult
  private func surfaceFlaggedCharge() -> Bool {
    guard let flagged = localDirectory.flaggedCharges.first else {
      appendMira(
        "Nothing on the card looks off — every charge on record matches something you did.",
        chips: ["Show my balances"], flow: "flagged-charge")
      return true
    }
    appendMira(
      "A charge from \(flagged.merchant) of \(flagged.amount.display) — \(flagged.reason) Is it yours?",
      chips: ["It's mine", "No — block it"],
      flow: "flagged-charge")
    return true
  }

  /// Cashback that was pending has landed: the answer to "did cashback land",
  /// never something the app says on its own. Crediting happens here, on the
  /// ask, and the offers document is the same one the answer always carried.
  @discardableResult
  private func surfaceCashbackCredits() -> Bool {
    let credited = localDirectory.creditPendingCashback()
    guard credited > 0, let summary = Offers.summary(localDirectory.cashback) else { return false }
    let currency = summary.currency
    appendMira(
      "\(Money(minorUnits: credited, currency: currency).display) of cashback landed — \(summary.credited.display) credited this month.",
      chips: ["Where else can I save?"],
      receipt: ReceiptSpec.offers(localDirectory.cashback),
      flow: "offers")
    return true
  }

  /// Subscriptions are the app's own record. The total, the best things to
  /// stop and the cancelling itself are arithmetic and one confirmation — no
  /// search, no model.
  private func subscriptionActionChips() -> [String] {
    let top = Subscriptions.savings(localDirectory.subscriptions)?.top(1).first
    return (top.map { ["Cancel \($0.name)"] } ?? [])
      + ["Find unused subscriptions", "What's charging this week?"]
  }

  private func handleSubscriptionIntent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    // Finding unused services belongs to the usage audit, even when the
    // question also says "subscriptions".
    if lowered.contains("unused") || lowered.contains("not using") || lowered.contains("still paying") {
      return false
    }
    let mentionsSubscriptions =
      lowered.contains("subscription") || lowered.contains("subscri") || lowered.contains("recurring")
      || lowered.range(of: "\\bsubs\\b", options: .regularExpression) != nil
    let cancelIntent =
      lowered.range(of: "\\b(cancel|stop paying|stop|drop|unsubscribe|cut)\\b", options: .regularExpression) != nil
    let saveIntent =
      lowered.contains("where else can i save") || lowered.contains("how can i save")
      || (lowered.contains("save") && (lowered.contains("month") || lowered.contains("year") || mentionsSubscriptions))

    // "undo" restores the last cancellation.
    if lowered == "undo", let last = localDirectory.subscriptions.last(where: { $0.cancelled }) {
      localDirectory.restoreSubscription(last.id)
      scheduleReminderRefresh()
      appendMira(
        "Back on: \(last.name).",
        chips: ["Show all subscriptions"],
        receipt: ReceiptSpec.savings(localDirectory.subscriptions),
        flow: "subscriptions")
      return true
    }

    // "cancel Adobe" — a specific charge.
    if cancelIntent, let match = Subscriptions.match(text, in: localDirectory.subscriptions), !match.cancelled {
      // The card named here must be the card that actually pays it. The record
      // is verified against the card this build holds; a block on a card the
      // person cannot see is not an action they can check.
      let card = Subscriptions.payingCard(match, mainCardLast4: mainCard.last4)
      if match.cardLast4 != card {
        var corrected = match
        corrected.cardLast4 = card
        localDirectory.updateSubscription(corrected)
      }
      localDirectory.cancelSubscription(match.id)
      scheduleReminderRefresh()
      // The chip that asked for this is fulfilled; it must not be offered again.
      dropChips { $0 == "Cancel \(match.name)" }
      let after = Subscriptions.savings(localDirectory.subscriptions)
      // Cancelling marks the record; blocking the merchant at the card is what
      // actually stops the charge, whatever the platform does.
      let block = " I also blocked \(match.name) on the card ending \(card), so a charge cannot come through even if it keeps trying."
      appendMira(
        "Cancelled \(match.name) — \(match.amount.display) a month, \(match.yearly.display) a year.\(block) Across everything you are now at \(after?.yearly.display ?? "—") a year.",
        chips: ["Show all subscriptions", "Undo", "Where else can I save?"],
        receipt: ReceiptSpec.savings(localDirectory.subscriptions),
        flow: "subscriptions")
      return true
    }

    // "block Adobe on my card" — the card lever on its own.
    if lowered.range(of: "\\bblock\\b", options: .regularExpression) != nil,
      let match = Subscriptions.match(text, in: localDirectory.subscriptions)
    {
      let card = Subscriptions.payingCard(match, mainCardLast4: mainCard.last4)
      localDirectory.blockMerchant(match.name, on: card)
      appendMira(
        "Blocked \(match.name) on the card ending \(card). The next charge will be declined; if you want it back, say unblock.",
        chips: ["Unblock \(match.name)", "Show all subscriptions"],
        flow: "subscriptions")
      return true
    }
    if lowered.hasPrefix("unblock"), let match = Subscriptions.match(text, in: localDirectory.subscriptions) {
      let card = Subscriptions.payingCard(match, mainCardLast4: mainCard.last4)
      localDirectory.unblockMerchant(match.name, on: card)
      appendMira(
        "Unblocked \(match.name) on the card ending \(card).",
        chips: ["Show all subscriptions"],
        flow: "subscriptions")
      return true
    }

    // "when does Netflix renew?" — a date the app already knows.
    if lowered.range(of: "\\b(when|what day|next charge)\\b", options: .regularExpression) != nil,
      let match = Subscriptions.match(text, in: localDirectory.subscriptions),
      let date = match.nextChargeDate()
    {
      let formatter = DateFormatter()
      formatter.dateFormat = "d MMMM"
      let blocked = localDirectory.isBlocked(match.name, on: match.cardLast4) ? " It is blocked on the card." : ""
      appendMira(
        "\(match.name) charges \(match.amount.display) on \(formatter.string(from: date)) — \(match.chargeIn()).\(blocked)",
        chips: ["Cancel \(match.name)", "Show all subscriptions"],
        flow: "subscriptions")
      return true
    }

    // The upcoming charges, asked for rather than announced: "what's charging
    // this week", "upcoming charges", "what charges soon", "show all
    // subscriptions". The words are the nudge's own, and the chips are its. The
    // week pattern wants the verb ("charge", "charges", "charging") followed by
    // a week, so "charged me this week" stays a complaint about a charge.
    let asksAboutUpcomingCharges =
      lowered.range(
        of: "\\bcharg(?:e|es|ing)\\b[^.!?\\n]{0,40}\\bweek\\b", options: .regularExpression) != nil
      || lowered.contains("upcoming charge") || lowered.contains("charges soon")
    if asksAboutUpcomingCharges { return surfaceRenewalReminders() }

    // "keep it" / "turn reminders off" from the renewal answer. "Keep it"
    // acknowledges the charge the answer named, so it finds the same soonest
    // charge the answer would.
    if lowered == "keep it", let soon = Subscriptions.chargingSoon(localDirectory.subscriptions, days: 31).first {
      appendMira(
        "Keeping \(soon.name).", chips: ["Show all subscriptions"], flow: "subscriptions")
      return true
    }
    if lowered.contains("reminders off") || lowered.contains("stop reminding") {
      setRenewalReminders(false)
      appendMira("No more renewal nudges. Say \"remind me before charges\" and I'll start again.")
      return true
    }
    if lowered.contains("remind me before charges") || lowered.contains("turn reminders on") {
      setRenewalReminders(true)
      appendMira(
        "I'll nudge you two or three days before each charge.",
        chips: ["Show all subscriptions"],
        flow: "subscriptions")
      return true
    }

    // The total, and the best few to look at.
    if mentionsSubscriptions || saveIntent, let savings = Subscriptions.savings(localDirectory.subscriptions) {
      let top = savings.top(3)
      let topLine = top.map { "\($0.name) \($0.yearly.display)" }.joined(separator: ", ")
      let saveLine = Money(
        minorUnits: top.reduce(Int64(0)) { $0 + $1.yearly.minorUnits }, currency: savings.monthly.currency)
      appendMira(
        "\(savings.count) subscriptions, \(savings.monthly.display) a month — \(savings.yearly.display) a year. The dearest are \(topLine); stopping those three alone saves \(saveLine.display) a year.",
        chips: subscriptionActionChips(),
        receipt: ReceiptSpec.savings(localDirectory.subscriptions),
        flow: "subscriptions")
      return true
    }
    return false
  }

  /// Sending money is a transfer, never research — and it is prepared here,
  /// not looked up. With a recipient and an amount the server proposes it; with
  /// either missing, the app asks for exactly what is missing.
  private func handleTransferIntent(_ text: String) -> Bool {
    guard StandaloneAgent.looksLikeMoneyMovement(text) else { return false }
    let amount = CheckoutFlow.amount(from: text)
    let recipient = localDirectory.contacts.first {
      !$0.name.isEmpty && text.localizedCaseInsensitiveContains($0.name)
    }
    // Complete enough for the transfer path below: let it through.
    if amount != nil, recipient != nil { return false }

    let rail = StandaloneAgent.transferRail(text)
    let what = rail ?? "transfer"
    if recipient == nil, amount == nil {
      let names = localDirectory.contacts.map(\.name)
      let who = names.isEmpty
        ? "Who should it go to?"
        : "Who should it go to — \(names.prefix(3).joined(separator: ", "))?"
      appendMira(
        "\(who) And how much? I'll prepare the \(what) and nothing moves until you approve it.",
        flow: "transfer")
      return true
    }
    if recipient == nil {
      appendMira(
        "Who should I send it to? I'll prepare the \(what) and nothing moves until you approve it.",
        flow: "transfer")
      return true
    }
    appendMira(
      "How much should I send to \(recipient!.name)? I'll prepare the \(what) and nothing moves until you approve it.",
      flow: "transfer")
    return true
  }

  /// The upcoming charges, in the words the renewal nudge used. Answered when
  /// asked — "what's charging this week", "upcoming charges", "what charges
  /// soon", "show all subscriptions" — and never volunteered: the app opens no
  /// conversation with it. When nothing is due this week the next charge is
  /// still the honest answer. It is the app's own record, so there is nothing
  /// to look up — the answer is arithmetic and a date.
  @discardableResult
  private func surfaceRenewalReminders(now: Date = Date()) -> Bool {
    let soon = Subscriptions.chargingSoon(localDirectory.subscriptions, days: 7, from: now)
    let next = soon.first
      ?? Subscriptions.chargingSoon(localDirectory.subscriptions, days: 31, from: now).first
    guard let first = next else {
      appendMira(
        "Nothing is due — there are no active subscriptions on record.",
        flow: "subscriptions")
      return true
    }

    let extra = soon.count > 1 ? " \(soon.count - 1) more charge this week." : ""
    let lead = soon.isEmpty ? "Nothing charges this week. " : ""
    appendMira(
      "\(lead)\(first.name) charges \(first.amount.display) \(first.chargeIn(now: now)) — cancel or keep it?\(extra)",
      chips: ["Cancel \(first.name)", "Keep it", "Show all subscriptions"],
      flow: "subscriptions")
    return true
  }

  // MARK: Reminders while the app is closed
  //
  // Three local notifications can outlive a session: a renewal nudge on the
  // charge day, a price-claim deadline three days out, and — only while the
  // proxy is unreachable — a quiet line about a watch check that could not run.
  // They are the same records the screens read, re-planned whenever one of them
  // changes. There is no push: `ReminderCenter` schedules them, and a
  // background refresh posts the lines that are only known later.

  /// The one switch, kept beside the records it is about, so the chat phrase
  /// and the Controls toggle are the same preference.
  var renewalReminders: Bool { localDirectory.renewalReminders }

  func setRenewalReminders(_ enabled: Bool) {
    localDirectory.setRenewalReminders(enabled)
    record(
      .preference, "Reminders",
      enabled
        ? "On: renewals, claim deadlines and watch checks."
        : "Off: nothing arrives while the app is closed.")
    scheduleReminderRefresh()
  }

  /// Re-plan from the records the app holds. The only network here is a health
  /// check: the watch-miss line is only true when the proxy really is
  /// unreachable at this moment.
  func refreshReminders(askIfNeeded: Bool = true) async {
    guard localDirectory.renewalReminders else {
      await ReminderCenter.shared.apply([])
      return
    }
    // The watch-miss line is the only part that depends on reachability, so the
    // health check is only worth making when a watch is actually standing.
    let hasWatch = tasks.values.contains { $0.watch?.active == true }
    let reachable = hasWatch ? await JevProxyClient(timeout: 4).availabilityMode() != nil : true
    let desired = Reminders.plan(
      subscriptions: localDirectory.subscriptions,
      claims: localDirectory.priceClaims,
      tasks: Array(tasks.values),
      proxyReachable: reachable)
    await ReminderCenter.shared.refresh(desired, askIfNeeded: askIfNeeded)
  }

  /// Called as the app goes to the background: snapshot what the app already
  /// knows so a wake only speaks about what happened after the person left, ask
  /// iOS for that wake, and re-plan without a permission prompt — nothing can
  /// be answered while the app is not on screen.
  func enterBackground() {
    ReminderNoticeStore().markTold(Array(tasks.values))
    MiraBackgroundRefresh.schedule()
    Task { await refreshReminders(askIfNeeded: false) }
  }

  /// A record the plan depends on changed, so the plan may have changed with it.
  private func scheduleReminderRefresh() {
    Task { await refreshReminders() }
  }

  /// "Track it", once an order has been placed. Each look moves the parcel one
  /// step along the same route every parcel takes, and shows the tracking slip.
  private func handleTrackIntent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    guard lowered == "track it" || lowered.hasPrefix("track the") else { return false }
    guard var order = lastOrder else { return false }
    order = order.advanced()
    lastOrder = order
    localDirectory.updateLastOrder(order)
    appendMira(
      order.statusLine,
      chips: order.isDelivered ? [] : ["Track it"],
      receipt: ReceiptSpec.tracking(order),
      flow: "order-tracking")
    return true
  }

  /// "Always use these" / "Change that" — the standing approval, on and off.
  private func handleConsentSetting(_ text: String) -> Bool {
    let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lowered.contains("always use these") || lowered == "just do it from now on" {
      localDirectory.setAutoCheckout(true)
      appendMira(
        "From now on I'll place orders like this without asking — up to \(ConsentPolicy.standingLimit.display) — and you'll see the receipt straight away. Say \"stop doing that\" and I'll ask again.",
        chips: ["Stop doing that"],
        flow: "consent")
      return true
    }
    if lowered.contains("stop doing that") || lowered.contains("stop that") {
      localDirectory.setAutoCheckout(false)
      appendMira(
        "Back to one confirmation per order.", chips: ["Show my balances"],
        flow: "consent")
      return true
    }
    return false
  }

  /// The checkout conversation: where it goes, which address to keep, which card
  /// pays, and one last yes before anything is recorded.
  private func handleCheckout(_ text: String) async -> Bool {
    if var draft = checkout {
      if StandaloneAgent.isNegative(text) || text.lowercased().contains("keep the fund") {
        checkout = nil
        appendMira(
          "Left it — nothing was ordered.", chips: ["Show my balances"],
          flow: "checkout")
        return true
      }
      switch draft.stage {
      case .price:
        guard let amount = CheckoutFlow.amount(from: text) else {
          appendMira("Tell me the price with its currency, for example USD 25.00, so I can show the card charge before placing it.", flow: "checkout")
          return true
        }
        draft.amount = amount
        draft.stage = .place
        checkout = draft
        if let main = draft.address {
          return advanceToPayment(&draft, note: "Delivering to your main address — \(main.text).")
        }
        appendMira("\(amount.display) for \(draft.item). Where should it go?", flow: "checkout")
        return true

      case .place:
        if CheckoutFlow.wantsMainAddressAnswer(text), let main = localDirectory.mainAddress {
          draft.address = main
          checkout = draft
          return advanceToPayment(&draft)
        }
        // "Yes" where a place is the question means the address already on
        // file — never a message handed to a model with no idea what it is.
        if StandaloneAgent.isAffirmative(text), let main = localDirectory.mainAddress {
          draft.address = main
          checkout = draft
          return advanceToPayment(&draft, note: "Delivering to your main address — \(main.text).")
        }
        guard let place = CheckoutFlow.placeAnswer(text) else { return false }
        let saved = localDirectory.saveAddress(place, makeMain: false)
        draft.address = saved
        draft.stage = .confirmMainAddress
        checkout = draft
        let shown = saved?.text ?? place
        appendMira(
          "Saved — \(shown). Shall I make it your main delivery address? I'll use it automatically from now on, and you can change it anytime.",
          chips: ["Yes, make it main", "No, just this once"],
          flow: "checkout")
        return true

      case .confirmMainAddress:
        guard let makeMain = CheckoutFlow.mainAddressAnswer(text) else { return false }
        if makeMain, let id = draft.address?.id {
          localDirectory.setMainAddress(id)
          draft.address = localDirectory.addresses.first { $0.id == id }
        }
        return advanceToPayment(&draft, note: makeMain ? nil : "Keeping it for this order only.")

      case .payment:
        // Choosing how to pay IS the approval: the order is placed, and the
        // receipt is the answer. "Yes" means the card already on the screen.
        if let choice = CheckoutFlow.paymentChoice(text) {
          switch choice {
          case .mainCard:
            draft.card = mainCard
          case .useVirtualCard:
            guard let card = draft.virtualCard else { return false }
            draft.card = card
          case .virtualCard:
            let card = CheckoutFlow.virtualCard(for: draft.merchant, holder: mainCard.holder)
            virtualCards.append(card)
            draft.virtualCard = card
            checkout = draft
            appendMira(
              "Here's a virtual card made for this order — its own number, its own limit, so nothing else can be charged to it.",
              chips: ["Pay with the virtual card", "Use my main card"],
              card: card,
              cardCaption: "\(card.masked) · \(card.summary) · valid through \(card.expiry)",
              flow: "checkout")
            return true
          }
          checkout = draft
          placeOrder(draft)
          return true
        }
        if StandaloneAgent.isAffirmative(text) || text.lowercased().contains("override") {
          draft.card = draft.card ?? mainCard
          if text.lowercased().contains("override") { draft.goalOverride = true }
          checkout = draft
          placeOrder(draft)
          return true
        }
        guard text.split(separator: " ").count <= 4 else { return false }
        appendMira(
          "Say which card pays — or I can make a virtual one for this order.",
          chips: ["Use this card", "New virtual card", "Cancel"],
          flow: "checkout")
        return true

      case .confirm:
        guard let place = CheckoutFlow.placeOrderAnswer(text) else { return false }
        checkout = nil
        if place {
          placeOrder(draft)
        } else {
          appendMira(
            "Left it — nothing was ordered.", chips: ["Show my balances"],
            flow: "checkout")
        }
        return true
      }
    }

    // Entry: a decision to buy. "buy the Brooks Ghost 15" starts the checkout;
    // "find me running shoes" stays research, because it is a search — and a
    // security order goes to the broker capability, not to a shop checkout.
    guard !StandaloneAgent.looksLikeSecurityOrder(text) else { return false }
    if let item = CheckoutFlow.namedPurchaseItem(in: text) {
      // A price the app already has — the research card's own — is used, so the
      // receipt states what was charged instead of leaving the amount blank.
      let known = CheckoutFlow.knownPick(for: item, in: Array(tasks.values))
      let amount = known?.amount ?? CheckoutFlow.amount(from: text)
      // A category or unpriced product needs real listings first. Asking the
      // user to invent a price here bypasses shopping research and thumbnails.
      guard amount != nil else { return false }
      startCheckout(
        item: item,
        merchant: known?.merchant,
        amount: amount,
        authorised: await carriesAuthorisation(text, amount: amount))
      return true
    }
    if CheckoutFlow.isContextPurchase(text), let pick = topPickContext() {
      // With standing approval, a priced pick is bought outright: that is what
      // "always use these" was for. Without it, the message may still authorise
      // the order early — or the checkout asks what it needs.
      let standing = ConsentPolicy.standingCovers(
        amount: pick.amount, standing: localDirectory.autoCheckout)
      var authorised = standing
      if !standing {
        authorised = await carriesAuthorisation(text, amount: pick.amount)
      }
      startCheckout(
        item: pick.name, merchant: pick.merchant, amount: pick.amount,
        authorised: authorised)
      return true
    }
    return false
  }

  /// Does this message carry its own authorisation to go ahead now? The typed
  /// read answers, when there is a proxy; without one, only an in-message
  /// phrase or standing approval counts, and the final confirmation stands.
  private func carriesAuthorisation(_ text: String, amount: Money?) async -> Bool {
    let standing = ConsentPolicy.standingCovers(amount: amount, standing: localDirectory.autoCheckout)
    guard ConsentPolicy.looksAuthorising(text) || standing else { return false }
    let known: [String: String] = [
      "address": localDirectory.mainAddress?.text ?? "",
      "card": mainCard.masked,
      "amount": amount?.display ?? "",
    ]
    let filled = Set(known.compactMap { $0.value.isEmpty ? nil : $0.key })
    let read = await orchestrator.consentRead(message: text, action: "checkout", known: known)
    switch ConsentPolicy.decision(from: read, known: filled) {
    case .proceed: return true
    case .ask, .confirm: return false
    }
  }

  private func advanceToPayment(_ draft: inout CheckoutDraft, note: String? = nil) -> Bool {
    draft.stage = .payment
    let card = mainCard
    draft.card = card
    checkout = draft
    let lead = note.map { "\($0) " } ?? ""
    // The offer engine runs before the payment, not after: what this purchase
    // returns, which offer, who funds it, and what is left of its cap.
    let decision = draft.amount.flatMap { amount in
      Offers.decide(
        amount: amount, purchase: "\(draft.item) \(draft.merchant ?? "")",
        merchant: draft.merchant, entries: localDirectory.cashback)
    }
    // With a price the line is arithmetic; without one it still names the
    // offer that applies and who funds it.
    let offerLine: String
    if let decision {
      offerLine = " \(decision.line)"
    } else if let offer = Offers.applicable(
      purchase: "\(draft.item) \(draft.merchant ?? "")", merchant: draft.merchant)
    {
      offerLine = " \(offer.title) (\(offer.funding.label))"
    } else {
      offerLine = ""
    }
    let priceLine = draft.amount.map { "\($0.display) — " } ?? ""
    appendMira(
      "\(lead)\(priceLine)Pay with your \(card.nickname) card ending \(card.last4)?\(offerLine) Choose it and I'll place the order — or I can make a virtual card for it.",
      chips: ["Use this card", "New virtual card"],
      card: card,
      cardCaption: "\(card.masked) · \(card.summary)",
      flow: "checkout")
    return true
  }

  /// Start a checkout for something the person decided to buy.
  ///
  /// Nothing the app already holds is asked for: a saved address is stated, not
  /// questioned. An authorisation carried by the message — or by standing
  /// approval — goes to the last look without the middle steps.
  func startCheckout(item: String, merchant: String? = nil, amount: Money? = nil, authorised: Bool = false) {
    var draft = CheckoutDraft(
      item: item, merchant: merchant, amount: amount,
      address: localDirectory.mainAddress, card: nil, stage: .place)

    guard amount != nil else {
      draft.stage = .price
      checkout = draft
      appendMira("I can simulate buying \(item). What price should I use? Give the amount and currency, for example USD 25.00.", flow: "checkout")
      return
    }

    if let main = draft.address {
      if authorised {
        // Given: standing approval, or the person said it in the message. The
        // order goes through and the receipt is the answer.
        checkout = draft
        placeOrder(draft)
        return
      }
      // Known: state it and move to the only thing left that a person owns.
      _ = advanceToPayment(&draft, note: "Delivering to your main address — \(main.text).")
      return
    }

    checkout = draft
    appendMira("Let's get it. Where should it go?", chips: [], flow: "checkout")
  }

  /// The simulated purchase: the app's own ledger records the debit, the
  /// platform step is labelled as the handoff it is. In this demo the order is
  /// as real as every other figure in the ledger — it is the store that isn't.
  private func placeOrder(_ draft: CheckoutDraft) {
    var draft = draft
    guard let amount = draft.amount, amount.minorUnits > 0 else {
      draft.stage = .price
      checkout = draft
      appendMira("What price should I use? Give the amount and currency before I charge the card.", flow: "checkout")
      return
    }
    draft.card = draft.card ?? mainCard
    guard draft.card?.frozen != true else {
      checkout = nil
      appendMira("Your card is frozen. No order was placed.", flow: "checkout")
      return
    }
    // A purchase that is large against a protected goal stops once, with the
    // trade-off stated, until the person overrides it.
    if !draft.goalOverride,
      let warning = GoalGuard.warning(purchase: amount, goals: localDirectory.goals)
    {
      checkout = draft
      appendMira(warning.line, chips: ["Override and place", "Keep the fund"], flow: "checkout")
      return
    }
    // The flow is over the moment the order is placed: without this the next
    // message ("Track it") was read as another checkout answer and looped.
    let reference = "M-\(Int.random(in: 10_000...99_999))"
    let assetKey = amount.currency.code.lowercased()
    let entry = JournalEntry(
      idempotencyKey: "order-\(reference)",
      date: Date(),
      memo: "Card \(draft.card?.last4 ?? "") · \(draft.item)",
      postings: [
        Posting(accountId: "world.\(assetKey)", amount: amount),
        Posting(
          accountId: Ledger.accountId(for: amount.currency),
          amount: Money(minorUnits: -amount.minorUnits, currency: amount.currency)),
      ])
    do {
      guard try ledger.post(entry) else { return }
    } catch {
      checkout = nil
      appendMira("I couldn't record the card charge, so no order was placed.", flow: "checkout")
      return
    }
    checkout = nil
    plan.total = ledger.clearedSpendableUSD
    let cardLine = draft.card.map { " Paid with the card ending \($0.last4)." } ?? ""
    record(
      .payment, "Order placed — \(reference)",
      "\(draft.item)\(draft.merchant.map { " from \($0)" } ?? "") · \(amount.display) to \(draft.address?.text ?? "your address").\(cardLine)")
    let placedOrder = PlacedOrder(
      reference: reference, item: draft.item, merchant: draft.merchant)
    lastOrder = placedOrder
    localDirectory.saveCardPurchase(entry, order: placedOrder)

    // Three things the app now knows because a purchase happened: a price to
    // watch inside the return window, an agent budget that was used, and the
    // receipt that backs both.
    if let amount = draft.amount {
      localDirectory.savePriceClaim(
        PriceClaim(
          item: draft.item, merchant: draft.merchant, paidMinor: amount.minorUnits,
          currencyCode: amount.currency.code, purchasedAt: Date(), windowDays: 30))
      scheduleReminderRefresh()
      if let agent = localDirectory.agentBudgets.first {
        localDirectory.spend(
          amount, from: agent.agent, note: "\(draft.item) · \(reference)")
      }
    }
    let approval = localDirectory.autoCheckout ? "Placed under your standing approval." : "Placed."
    // What the offer engine promised at the payment step is recorded with the
    // order, pending until it lands.
    var cashbackLine: String?
    if let amount = draft.amount,
      let decision = Offers.decide(
        amount: amount, purchase: "\(draft.item) \(draft.merchant ?? "")",
        merchant: draft.merchant, entries: localDirectory.cashback)
    {
      localDirectory.recordCashback(
        CashbackEntry(
          offerID: decision.offer.id, offerTitle: decision.offer.title,
          cardLast4: draft.card?.last4 ?? "4872", merchant: draft.merchant ?? "the store",
          item: draft.item, category: Offers.category(for: draft.item),
          amountMinor: amount.minorUnits, currencyCode: amount.currency.code,
          earnedMinor: decision.expected.minorUnits, ratePercent: decision.offer.ratePercent))
      cashbackLine = "Cashback \(decision.expected.display) pending — \(decision.offer.title)."
    }
    let receipt = ReceiptSpec.purchase(
      item: draft.item, merchant: draft.merchant, address: draft.address?.text,
      card: draft.card, amount: draft.amount, reference: reference,
      cashback: cashbackLine)
    appendMira(
      "\(approval) I'll tell you here if anything moves.",
      chips: localDirectory.autoCheckout ? ["Track it"] : ["Track it", "Always use these"],
      receipt: receipt,
      flow: "order")
  }

  /// The best pick of the most recent shopping task: what "buy it" means a
  /// moment after the card showed it.
  private func topPickContext() -> (name: String, merchant: String?, amount: Money?)? {
    let recent = tasks.values
      .filter { $0.kind == "shopping" && $0.status == .completed && !$0.options.isEmpty }
      .sorted { $0.updatedAt > $1.updatedAt }
      .first
    guard let pick = recent?.options.first else { return nil }
    let merchant = pick.url.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }
    return (pick.name, merchant, CheckoutFlow.amount(from: pick.priceNote))
  }

  // MARK: Suggestion

  /// At most one contextual suggestion, and only one the user has allowed.
  private func refreshSuggestion() {
    guard controls.personalizedSuggestions, controls.assistantEnabled else {
      suggestion = nil
      return
    }
    if plan.status.isBalanced && !plan.isApproved {
      suggestion = MiraSuggestion(
        title: "Your plan is ready to review",
        detail: "Four allocations, all of your \(clearedUSD.display) accounted for.",
        actionTitle: "Review and approve",
        act: .openPlan
      )
    } else if let payment = activePayment, payment.state.isUnknown {
      suggestion = MiraSuggestion(
        title: "One payment needs reconciling",
        detail:
          "Mira did not get an answer about the last payment. Nothing is retried until this is resolved.",
        actionTitle: "Reconcile now",
        act: .reconcile
      )
    } else if pendingUSD.minorUnits > 0 {
      suggestion = MiraSuggestion(
        title: "\(pendingUSD.display) is still pending",
        detail: "It is not available to spend until it clears.",
        actionTitle: "See activity",
        act: .openActivity
      )
    } else {
      suggestion = nil
    }
  }

  // MARK: History

  private func record(_ kind: ActionRecord.Kind, _ title: String, _ detail: String) {
    actionHistory.insert(ActionRecord(kind: kind, title: title, detail: detail), at: 0)
    if actionHistory.count > 200 { actionHistory.removeLast() }
  }

  // MARK: Eligibility

  private func eligibilitySummary() -> String {
    let outcome = engine.evaluate(context: context, productId: "usd-account")
    switch outcome {
    case .available(let reason): return reason
    case .needsInformation(let questions): return questions.first ?? "More information is needed."
    case .unavailable(let reason): return reason
    }
  }
}

// MARK: - Instruction parsing

/// Conservative extraction from pasted text.
///
/// Deliberately dumb and deterministic: the brief requires that a vision or
/// language model's extraction is never authoritative, and this parser is the
/// same idea in miniature. Anything it cannot read confidently stays nil.
enum InstructionParser {
  struct Extracted: Sendable {
    var amount: Money?
    var handle: String?
    var label: String?
  }

  static func parse(_ text: String) -> Extracted {
    var result = Extracted()

    // Explicit currency figures only. "R$ 150,00", "BRL 150.00", "150 BRL".
    result.amount = firstBRLAmount(in: text)

    // A synthetic key is only accepted when it carries the sim- marker, so
    // a real-looking key in a demo invoice can never be used.
    if let range = text.range(
      of: "\(Payee.syntheticMarker)[A-Za-z0-9\\-]+", options: .regularExpression)
    {
      result.handle = String(text[range])
    }

    // A payee label from a line that names the recipient.
    for line in text.split(separator: "\n") {
      let lowered = line.lowercased()
      if lowered.contains("nome") || lowered.contains("name") || lowered.contains("recebedor")
        || lowered.contains("to:")
      {
        let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty { result.label = cleaned }
      }
    }

    return result
  }

  /// Parses the first BRL figure, tolerating both `1.234,56` and `1,234.56`.
  static func firstBRLAmount(in text: String) -> Money? {
    let pattern = "(?i)(?:R\\$|BRL)\\s*([0-9][0-9.,]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      let valueRange = Range(match.range(at: 1), in: text)
    else { return nil }
    let raw = String(text[valueRange])
    guard let decimal = decimal(fromLocalised: raw) else { return nil }
    return Money(majorUnits: decimal, currency: .brl)
  }

  /// Resolves the ambiguity between `1.234,56` and `1,234.56` by looking at
  /// whichever separator appears last.
  static func decimal(fromLocalised raw: String) -> Decimal? {
    let lastComma = raw.lastIndex(of: ",")
    let lastDot = raw.lastIndex(of: ".")
    var normalised = raw

    switch (lastComma, lastDot) {
    case (nil, nil):
      normalised = raw
    case (.some, nil):
      normalised = raw.replacingOccurrences(of: ",", with: ".")
    case (nil, .some):
      normalised = raw
    case (.some(let comma), .some(let dot)):
      if comma > dot {
        // 1.234,56 -> 1234.56
        normalised = raw.replacingOccurrences(of: ".", with: "")
          .replacingOccurrences(of: ",", with: ".")
      } else {
        // 1,234.56 -> 1234.56
        normalised = raw.replacingOccurrences(of: ",", with: "")
      }
    }

    return Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX"))
  }
}
