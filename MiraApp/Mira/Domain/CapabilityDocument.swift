import Foundation

// MARK: - What this build can actually do
//
// The app mirror of `server/lib/capability-document.mjs`, and the answer to
// "what can move money in this build today, and what is simulated?". It is
// assembled from the catalogues this code already runs on — the typed actions
// (`AgentAction.Kind`), the money-desk engines, the commit paths and the
// refusals — so a new action or engine cannot be added without a test failing
// until it is placed in a section.
//
// Five sections, in the order a person asks about them: what is instant, what
// is prepared, what moves after one approval, what runs as research, and what
// is refused. Money is simulated in every one of them.

/// One line of the document: an id the code uses, and the words a person reads.
struct CapabilityItem: Equatable, Sendable {
  let id: String
  let label: String
}

enum CapabilitySectionID: String, CaseIterable, Sendable {
  case instant
  case prepares
  case approval
  case research
  case refuses

  var label: String {
    switch self {
    case .instant: return "Answered here and now, from your own records"
    case .prepares: return "Prepared, with nothing moved"
    case .approval: return "Moves only after one approval"
    case .research: return "Runs as research, on the Mac runtime, preparation only"
    case .refuses: return "Refused, deterministically"
    }
  }
}

/// Which half of the product an action belongs to. The names match the server's
/// verb classes (`verbs.mjs`): observe reads, prepare composes, commit moves.
enum CapabilityClass: String, Sendable {
  case observe
  case prepare
  case commit
}

/// The twelve money-desk engines, each with the flow id the session uses. This
/// is the desk's own catalogue: `flow` is the string passed to `appendMira`.
enum MoneyDeskEngine: String, CaseIterable, Sendable {
  case zombies
  case fees
  case idleCash = "idle-cash"
  case negotiation
  case income
  case split
  case credit
  case flaggedCharge = "flagged-charge"
  case priceClaim = "price-claim"
  case claims
  case agentBudget = "agent-budget"
  case goals

  var label: String {
    switch self {
    case .zombies: return "the charges nobody uses"
    case .fees: return "a fee radar over three months"
    case .idleCash: return "what is safe to put away"
    case .negotiation: return "a renewal ask, drafted"
    case .income: return "income carved into tax, buffer and spendable"
    case .split: return "a split, laid out for the people in it"
    case .credit: return "what keeps credit utilisation under the line"
    case .flaggedCharge: return "a charge you do not recognise, reviewed"
    case .priceClaim: return "a price-drop claim, prepared"
    case .claims: return "a compensation claim, prepared"
    case .agentBudget: return "what an agent budget still allows"
    case .goals: return "a warning when a purchase touches a goal"
    }
  }

  var capabilityClass: CapabilityClass {
    switch self {
    case .negotiation, .income, .split, .priceClaim, .claims: return .prepare
    case .zombies, .fees, .idleCash, .credit, .flaggedCharge, .agentBudget, .goals: return .observe
    }
  }
}

/// The commit paths this app owns. The first five ids are the server's commit
/// verbs; `checkout.commit` is the order flow the app runs itself.
enum CommitVerb: String, CaseIterable, Sendable {
  case transfer = "transfer.commit"
  case swap = "fx.swap"
  case cardFreeze = "card.freeze"
  case cardBlock = "card.block"
  case subscriptionCancel = "subscription.cancel"
  case checkout = "checkout.commit"

  var label: String {
    switch self {
    case .transfer: return "sending money to a saved recipient"
    case .swap: return "a currency swap at a rate we quoted"
    case .cardFreeze: return "freezing or unfreezing the card"
    case .cardBlock: return "blocking a merchant on the card"
    case .subscriptionCancel: return "cancelling a subscription"
    case .checkout: return "placing an order from a checkout"
    }
  }
}

/// The research engines the Mac runtime runs. Mirrors the ids and labels in
/// `server/lib/capabilities.mjs`; both are research and preparation only, and
/// no vendor is connected.
enum ResearchEngine: String, CaseIterable, Sendable {
  case restaurant
  case shopping
  case travel
  case auction
  case invest
  case watch
  case research
  case admin

  var label: String {
    switch self {
    case .restaurant: return "restaurant discovery and reservation preparation"
    case .shopping: return "product research and purchase preparation"
    case .travel: return "travel research and booking preparation"
    case .auction: return "auction search and bidding preparation"
    case .invest: return "investment research and order preparation"
    case .watch: return "a standing watch and price alerts"
    case .research: return "general research and comparison"
    case .admin: return "personal admin and planning"
    }
  }
}

/// The refusals, with the exact words the app uses. The lines come from the
/// guards themselves — one wording each, so the document cannot drift from
/// what is actually said.
enum CapabilityRefusal: String, CaseIterable, Sendable {
  case advice
  case rateNotQuoted = "rate_not_quoted"
  case unpricedCorridor = "unpriced_corridor"
  case rulesOverride = "rules_override"
  case inventedFigure = "invented_figure"

  var label: String {
    switch self {
    case .advice: return "investment, tax and legal advice"
    case .rateNotQuoted: return "a rate we did not quote"
    case .unpricedCorridor: return "a corridor this build does not price"
    case .rulesOverride: return "instructions that try to change my rules, limits or approvals"
    case .inventedFigure: return "an invented figure in a model-written line"
    }
  }

  var line: String {
    switch self {
    case .advice: return StandaloneAgent.adviceRefusal
    case .rateNotQuoted: return StandaloneAgent.rateBookingRefusal
    case .unpricedCorridor: return "Any pair among \(CorridorSupport.quotedCurrenciesPhrase). "
        + "I will not invent a rate outside them."
    case .rulesOverride: return MiraRouteClient.refusalLine
    case .inventedFigure: return "Let me not put a number on that without checking your account first."
    }
  }
}

enum CapabilityDocument {
  struct Section: Equatable, Sendable {
    let id: CapabilitySectionID
    let items: [CapabilityItem]
    var label: String { id.label }
  }

  /// The typed action's half of the document. Every `AgentAction.Kind` must
  /// appear here exactly once; the test pins that.
  static func kindSection(_ kind: AgentAction.Kind) -> CapabilitySectionID {
    switch kind {
    case .showBalance, .showBudget, .openCardControls, .openReceive, .reply:
      return .instant
    case .askTransferDetails, .proposeTransfer, .proposeBudgetUpdate, .requirementsFlow, .agentTask:
      return .prepares
    case .transferReceipt:
      // The record that a commit landed — shown after the approval, never an
      // action of its own.
      return .approval
    }
  }

  static func kindLabel(_ kind: AgentAction.Kind) -> String {
    switch kind {
    case .showBalance: return "your balances"
    case .showBudget: return "this week's budget and the reserve"
    case .openCardControls: return "the card and its controls"
    case .openReceive: return "your receiving details"
    case .reply: return "a short explanation or a follow-up"
    case .askTransferDetails: return "a transfer, with the missing detail asked for"
    case .proposeTransfer: return "a transfer, ready for your confirmation"
    case .proposeBudgetUpdate: return "a change to the weekly budget"
    case .requirementsFlow: return "the requirements checklist when no provider is connected"
    case .agentTask: return "a research or comparison task"
    case .transferReceipt: return "the receipt after you approve a transfer"
    }
  }

  static var sections: [Section] {
    let kinds = AgentAction.Kind.allCases
    func kindItems(_ section: CapabilitySectionID) -> [CapabilityItem] {
      kinds
        .filter { kindSection($0) == section }
        .map { CapabilityItem(id: $0.rawValue, label: kindLabel($0)) }
    }
    func engineItems(_ section: CapabilityClass) -> [CapabilityItem] {
      MoneyDeskEngine.allCases
        .filter { $0.capabilityClass == section }
        .map { CapabilityItem(id: $0.rawValue, label: $0.label) }
    }

    return [
      Section(
        id: .instant,
        items: kindItems(.instant) + engineItems(.observe)),
      Section(
        id: .prepares,
        items: kindItems(.prepares) + engineItems(.prepare)),
      Section(
        id: .approval,
        items: CommitVerb.allCases.map { CapabilityItem(id: $0.rawValue, label: $0.label) }
          + kindItems(.approval)),
      Section(
        id: .research,
        items: ResearchEngine.allCases.map { CapabilityItem(id: $0.rawValue, label: $0.label) }),
      Section(
        id: .refuses,
        items: CapabilityRefusal.allCases.map { CapabilityItem(id: $0.rawValue, label: $0.label) }),
    ]
  }

  static func items(_ id: CapabilitySectionID) -> [CapabilityItem] {
    sections.first { $0.id == id }?.items ?? []
  }

  /// The answer, rendered from the document — never a second list to keep in
  /// step. The same five sections the proxy answers from.
  static var answer: String {
    func names(_ id: CapabilitySectionID) -> String {
      items(id).map(\.label).joined(separator: ", ")
    }
    return [
      "This build is simulated money, and it is honest about the line. Instantly, from your own records: \(names(.instant)).",
      "Prepared, with nothing moved: \(names(.prepares)).",
      "One approval, then it moves: \(names(.approval)).",
      "\(items(.research).count) engines run as research on the Mac runtime, and every one of them is preparation only — no vendor is connected.",
      "I refuse \(items(.refuses).map(\.label).joined(separator: ", ")).",
    ].joined(separator: " ")
  }

  /// The plain shapes of "tell me about this build". The proxy's typed read
  /// catches paraphrases; this answers the plain phrasings with no network.
  static func asksAboutThisBuild(_ message: String) -> Bool {
    let patterns = [
      #"\bwhat can (?:you|this|the app|this build|the product|it|mira)\b"#,
      #"\bwhat (?:does|do) (?:this|you|the app|mira|the build|it)(?:\s+\w+){0,2}\s+(?:do|offer|support|handle)\b"#,
      #"\bwhat (?:can't|can’t|cannot|don't|do not|doesn't|does not) (?:you|this|the app|mira|it|this build)\b"#,
      #"\bwhat (?:actually )?moves? money\b"#,
      #"\bmove money (?:in|here|in this build)\b"#,
      #"\bwhat(?:'s| is) simulated\b"#,
      #"\bwhat needs (?:my|your|one|an?) approval\b"#,
      #"\bwhat do you do\b"#,
      #"\bcapabilit(?:y|ies)\b"#,
      #"\bwhat are you (?:able|allowed) to do\b"#,
      #"\bhow does (?:mira|this|the app) work\b"#,
      #"\bwhat does the user see\b"#,
    ]
    return patterns.contains {
      message.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }
}
