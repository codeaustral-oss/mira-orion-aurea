import Foundation

/// Questions that can be added to History as individual, working chats.
enum EverydayChatPrompts {
  static let all = [
    "Where is my money right now?",
    "How much do I have?",
    "Show my balances",
    "Show my holdings",
    "How much is left in this week's budget?",
    "What's my weekly budget?",
    "Can I spend this week?",
    "How much is my reserve?",
    "Freeze my card",
    "Is my card active?",
    "Open card controls",
    "How do I receive money?",
    "Show my account details",
    "Show all subscriptions",
    "How many subscriptions do I have?",
    "How much do my subscriptions cost each month?",
    "I need to save money from my subs",
    "Show my recurring charges",
    "When does Netflix renew?",
    "When does Spotify renew?",
    "What upcoming charges do I have?",
    "What fees have I paid?",
    "Where are my fees?",
    "Find unused subscriptions",
    "What am I still paying for that I don't use?",
    "Show cashback",
    "What offers can I use?",
    "What rewards do I have?",
    "What tier am I on?",
    "How do I upgrade my account?",
    "Show my piggy banks",
    "How are my savings goals?",
    "How much is in my goal?",
    "How much is safe to put away?",
    "Is there idle cash I could save?",
    "Buy cat food",
    "Purchase headphones",
    "Buy a book",
    "Buy running shoes",
    "Send money",
    "Transfer money to a friend",
    "Send USD 25 to a contact",
    "Show my splits",
    "Split USD 120 with Ana and Rui",
    "Can I afford USD 80?",
    "Is there an unknown charge?",
    "Can you negotiate my contract?",
    "What's my credit card utilization?",
    "What if my package is damaged?",
    "What can you actually do?",
  ]
}

// MARK: - Persisted conversations
//
// The first version of the chat home kept its transcript in memory for the life
// of the process. Tapping "New conversation" threw the only copy away, and a
// relaunch silently lost everything. This makes a conversation a first-class,
// named, persisted thing:
//
//   · every thread is stored, so starting a new one preserves the old
//   · switching threads saves the one you were in and restores the one you pick
//   · the pending transfer and the per-proposal state travel with the thread, so
//     a settled transfer reopens as settled instead of offering to send again
//
// The file holds transcript text and typed actions only. It never holds a
// credential, and a transfer is still only ever booked by the relay.

/// One persisted turn. The specialist is rebuilt from the shared roster id;
/// structured documents stay with the answer that produced them.
struct StoredTurn: Codable, Identifiable, Sendable {
  var id: UUID
  /// "user" or "mira".
  var role: String
  var at: Date
  var text: String
  var specialistId: String?
  var action: AgentAction?
  var replySource: String?
  var isError: Bool
  var receipt: ReceiptSpec?
  /// Optional so conversations saved before actions were persisted still open.
  var chips: [String]?
  var flow: String?

  init(
    id: UUID, role: String, at: Date, text: String, specialistId: String?,
    action: AgentAction?, replySource: String?, isError: Bool,
    receipt: ReceiptSpec? = nil, chips: [String]? = nil, flow: String? = nil
  ) {
    self.id = id
    self.role = role
    self.at = at
    self.text = text
    self.specialistId = specialistId
    self.action = action
    self.replySource = replySource
    self.isError = isError
    self.receipt = receipt
    self.chips = chips
    self.flow = flow
  }
}

/// A named conversation and everything that belongs to continuing it.
struct StoredThread: Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var createdAt: Date
  var updatedAt: Date
  /// The specialist the user pinned in this thread, if any.
  var activeAgentId: String?
  var turns: [StoredTurn]
  /// Transfer proposal state keyed by turn id, encoded as a short string.
  var proposalStates: [String: String]
  var pendingTo: String?
  var pendingAsset: String?
  var pendingAmountMinor: Int64?
  /// Identifies a loaded collection without changing the chat's visible turns.
  var collectionId: String? = nil

  var isEmpty: Bool { turns.isEmpty }

  /// A one-line hint of the conversation for the threads list: the last thing
  /// said, flattened so it never breaks the row's height.
  var preview: String? {
    for turn in turns.reversed() {
      let text = turn.text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
      if !text.isEmpty { return text }
    }
    return nil
  }
}

struct ChatThreadPayload: Codable, Sendable {
  var version: Int = 1
  var activeThreadId: UUID?
  var threads: [StoredThread] = []
  /// The profile the transcript belongs to. A conversation happened in one
  /// person's session, so a file written for someone else is not carried into
  /// this one. Nil means a file written before profiles existed.
  var profileSlug: String?
}

/// An illustrated transcript for each profile. These are authored examples,
/// never model output or completed financial actions. The first real message
/// starts a separate conversation so the example remains intact in History.
enum ExampleConversation {
  static func title(for persona: DemoPersona) -> String {
    switch persona.id {
    case "orion-thiago": return "Thiago · Money and momentum"
    case "orion-valentina": return "Valentina · Studio and Madrid"
    case "orion-mateo": return "Mateo · Every decision counts"
    case "aurea-helena": return "Helena · Gallery and reserve"
    case "aurea-rafael": return "Rafael · A life on tour"
    case "aurea-ines": return "Inés · Through harvest"
    default: return persona.name
    }
  }

  static func make(for persona: DemoPersona, now: Date = Date()) -> StoredThread {
    let exchanges = script(for: persona.id)
    var turns: [StoredTurn] = []
    for (index, exchange) in exchanges.enumerated() {
      let at = now.addingTimeInterval(TimeInterval(index * 120))
      turns.append(StoredTurn(
        id: UUID(), role: "user", at: at, text: exchange.0,
        specialistId: nil, action: nil, replySource: nil, isError: false))
      turns.append(StoredTurn(
        id: UUID(), role: "mira", at: at.addingTimeInterval(20), text: exchange.2,
        specialistId: exchange.1, action: nil, replySource: "example", isError: false))
    }
    return StoredThread(
      id: UUID(), title: title(for: persona), createdAt: now, updatedAt: now,
      activeAgentId: nil, turns: turns, proposalStates: [:],
      pendingTo: nil, pendingAsset: nil, pendingAmountMinor: nil)
  }

  private static func script(for id: String) -> [(String, String, String)] {
    switch id {
    case "orion-thiago": return [
      ("Can I buy the MacBook this month?", "analyst", "Your MacBook fund has USD 1,050 of its USD 2,400 target. That leaves USD 1,350. I can compare the gap with this week's plan before you decide."),
      ("What am I paying for that I don't use?", "scout", "Max has not been used for 96 days. Cloud hosting also appears twice on the same day. Review those charges before cancelling or disputing either one."),
      ("Put 20% of the Northwind payment into my runway.", "quartermaster", "Northwind's USD 2,150 is still pending. Twenty percent would be USD 430. I can prepare that allocation after it clears; no money has moved."),
      ("And if the late-night store charge isn't mine?", "sentinel", "Open the flagged charge and review the merchant and time. You can freeze the simulated card from Card while you investigate.")
    ]
    case "orion-valentina": return [
      ("This month is thin. What can I move?", "navigator", "The Kessler invoice is pending, so I would plan from your cleared USD 3,180. Your studio deposit and Madrid move remain separate goals."),
      ("Where did fees leak away?", "analyst", "Your activity includes a weekend transfer fee and an ATM charge abroad. I can show each recorded fee; a new FX quote needs a current rate."),
      ("Did Adobe charge me twice?", "sentinel", "Two Adobe charges appear within 24 hours. Compare their receipts before disputing one; I cannot tell from the ledger alone whether both are valid."),
      ("Move USD 300 to my studio fund.", "quartermaster", "The studio fund has USD 2,350 toward USD 6,000. I can prepare a USD 300 allocation for your review. Nothing moves without confirmation.")
    ]
    case "orion-mateo": return [
      ("How much can I spend tonight?", "analyst", "Your weekly plan is about USD 110. I would check the live week remainder before giving you tonight's number; your BRL 340 balance is a separate account."),
      ("Did iFood charge me twice?", "sentinel", "iFood Clube appears twice in your recent activity. Open both entries and compare the dates and amounts before taking action."),
      ("Could I save for the bike?", "navigator", "The bike has BRL 420 of its BRL 1,800 target. A BRL 50 contribution would leave BRL 1,330 to go, if you approve it."),
      ("What if I need to send money locally?", "broker", "I can show the recipient, current quote and total cost before a Pix payment. The payment only proceeds after your confirmation.")
    ]
    case "aurea-helena": return [
      ("What came in from New York?", "accountant", "The New York sale has USD 18,000 pending. Your cleared USD 42,000 is available separately; the pending sale is not yet spendable."),
      ("What is shipping insurance costing me?", "guardian", "Shipping insurance appears twice in recent activity. Compare the policies and invoices before calling either charge a duplicate."),
      ("Can we prepare for Basel?", "planner", "I would separate the Basel costs from your protected reserve and the chapel fresco. The gallery endowment has USD 34,000 toward USD 120,000."),
      ("Could we lower the atelier electricity bill?", "negotiator", "The renewal is in 12 days and a cheaper competitor is recorded. I can draft terms to compare; I cannot change the contract without you.")
    ]
    case "aurea-rafael": return [
      ("The Vienna hotel charged me twice.", "guardian", "Two Vienna hotel charges appear in your activity. Compare the booking and folio first. I can help prepare a claim once the duplicate is confirmed."),
      ("How is the cello fund?", "accountant", "The cello fund has EUR 12,000 toward EUR 45,000. The remaining gap is EUR 33,000; your tour income and teaching income should stay distinct in the plan."),
      ("Could I move teaching income there?", "treasurer", "Your teaching income arrives in USD while the cello goal is in EUR. I would show a current conversion quote and fee before preparing an allocation for approval."),
      ("Split the quartet dinner four ways.", "concierge", "I can divide the recorded dinner into four equal shares and prepare requests. I would need the final amount and each colleague's details before sending anything.")
    ]
    case "aurea-ines": return [
      ("How much runway do we have until harvest?", "planner", "The export settlement of USD 7,400 is pending. I would use the cleared USD 11,600 and keep the harvest reserve separate when mapping the weeks ahead."),
      ("Was irrigation equipment billed twice?", "guardian", "I found two irrigation equipment charges in recent activity. Check the invoices and delivery references before disputing either one."),
      ("Set aside 10% of the export payment.", "treasurer", "Ten percent of USD 7,400 would be USD 740. I can prepare that for the harvest reserve after the settlement clears; nothing has moved."),
      ("What did the trade fair cost?", "accountant", "I can group the recorded fair travel and related spending. Any costs outside this account would need to be added before calling it a complete total.")
    ]
    default: return []
    }
  }
}

/// A tiny, atomic, local store for conversations.
///
/// It mirrors `LocalDirectoryStore`: synchronous, temp-file-then-rename, and
/// tolerant of a missing file. The transcript is small, so simplicity beats a
/// database here.
final class ChatThreadStore {
  private let path: URL

  init(path: URL? = nil) {
    self.path = path ?? ChatThreadStore.defaultPath()
  }

  static func defaultPath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Mira", isDirectory: true)
      .appendingPathComponent("chats.json")
  }

  func load() -> ChatThreadPayload {
    do {
      let data = try Data(contentsOf: path)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let payload = try decoder.decode(ChatThreadPayload.self, from: data)
      return ChatThreadPayload(
        version: payload.version,
        activeThreadId: payload.activeThreadId,
        threads: payload.threads,
        profileSlug: payload.profileSlug)
    } catch {
      // A missing file is the normal first-run case, not an error.
      return ChatThreadPayload(version: 1, activeThreadId: nil, threads: [])
    }
  }

  func save(_ payload: ChatThreadPayload) {
    do {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(payload)
      let tmp = path.appendingPathExtension("tmp")
      try data.write(to: tmp, options: .atomic)
      _ = try? FileManager.default.removeItem(at: path)
      try FileManager.default.moveItem(at: tmp, to: path)
    } catch {
      // Losing a transcript write never blocks the conversation; the in-memory
      // thread is still intact for this session.
    }
  }
}

// MARK: - Proposal state on the wire

/// A short, stable encoding of a transfer's life, so a reopened thread can show
/// that a transfer already settled instead of offering to send it again.
extension TransferProposalState {
  static func encodeProposal(_ state: TransferProposalState) -> String {
    switch state {
    case .proposed: return "proposed"
    // A send that was in flight when the app stopped is treated as still
    // proposed. Re-confirming is safe: the relay's idempotency key is derived
    // from the turn, so the same key returns the original receipt.
    case .sending: return "proposed"
    case .settled(let receipt): return "settled:\(receipt)"
    case .failed(let message): return "failed:\(message)"
    }
  }

  static func decodeProposal(_ raw: String) -> TransferProposalState {
    if raw == "proposed" { return .proposed }
    if raw.hasPrefix("settled:") {
      return .settled(receipt: String(raw.dropFirst("settled:".count)))
    }
    if raw.hasPrefix("failed:") {
      return .failed(String(raw.dropFirst("failed:".count)))
    }
    return .proposed
  }
}
