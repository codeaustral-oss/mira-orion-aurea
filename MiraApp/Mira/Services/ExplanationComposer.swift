import Foundation

// MARK: - Snapshot

/// Everything the composer is allowed to reason about, captured as values.
///
/// The composer is pure and takes no other input, which is what keeps the
/// numbers in an explanation provably identical to the numbers on screen.
struct MiraSnapshot: Sendable {
  var clearedUSD: Money
  var pendingUSD: Money
  var brlBalance: Money
  var plan: AllocationPlan
  var currentWeekIndex: Int
  var cardFrozen: Bool
  var activePayment: Payment?
  var context: UserContext
  var eligibilityNote: String
  /// True when the app only has partial financial data for this user.
  var partialData: Bool

  init(
    clearedUSD: Money,
    pendingUSD: Money,
    brlBalance: Money,
    plan: AllocationPlan,
    currentWeekIndex: Int,
    cardFrozen: Bool,
    activePayment: Payment?,
    context: UserContext,
    eligibilityNote: String,
    partialData: Bool
  ) {
    self.clearedUSD = clearedUSD
    self.pendingUSD = pendingUSD
    self.brlBalance = brlBalance
    self.plan = plan
    self.currentWeekIndex = currentWeekIndex
    self.cardFrozen = cardFrozen
    self.activePayment = activePayment
    self.context = context
    self.eligibilityNote = eligibilityNote
    self.partialData = partialData
  }
}

// MARK: - Composer

/// Turns a routing decision plus computed state into a grounded answer.
///
/// Hard rule: every figure below is read from `MiraSnapshot` or computed from
/// it. The routing label arrives from the provider; nothing numerical does.
struct ExplanationComposer: Sendable {
  init() {}

  func compose(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    // A routing label with no confidence, or below the floor, is not a
    // licence to guess. Ask, and hand over explicit controls.
    if decision.didReachNoFit || decision.mode == .unavailable {
      return clarification(decision: decision, snapshot: snapshot)
    }

    switch decision.intent {
    case .budget:
      return budget(decision: decision, snapshot: snapshot)
    case .balance:
      return balance(decision: decision, snapshot: snapshot)
    case .preparePayment:
      return payment(decision: decision, snapshot: snapshot)
    case .reserve:
      return reserve(decision: decision, snapshot: snapshot)
    case .earnInformation:
      return earn(decision: decision, snapshot: snapshot)
    case .cardHelp:
      return card(decision: decision, snapshot: snapshot)
    case .receive:
      return receive(decision: decision, snapshot: snapshot)
    case .support:
      return support(decision: decision, snapshot: snapshot)
    case .ambiguous, .unsupported:
      return clarification(decision: decision, snapshot: snapshot)
    }
  }

  // MARK: Budget — the Journey C question

  private func budget(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    let plan = snapshot.plan
    let week = plan.weeks.first { $0.index == snapshot.currentWeekIndex }

    guard let week else {
      return clarification(decision: decision, snapshot: snapshot)
    }

    let left = week.remaining
    let spent = week.spent
    let allowance = week.allowance

    var body = """
      \(left.display) is left of this week's budget.

      Week \(week.index) started with \(allowance.display). \
      \(spent.isZero ? "Nothing has been spent from it yet." : "You have spent \(spent.display) from it so far.")
      """

    if plan.spentFromDiscretionary.isZero {
      body += "\n\nYour reserve of \(plan.reserveMoney.display) is untouched."
    } else {
      body +=
        "\n\nYour reserve of \(plan.reserveMoney.display) is held separately and is not part of this figure."
    }

    if snapshot.partialData {
      body += "\n\nThis estimate uses only the accounts Mira can currently see."
    }

    var citations = [
      "Week \(week.index) allowance: \(allowance.display) — your plan, set \(Self.date(plan.weeklyBudget.updatedAt))",
      "Spent this week: \(spent.display) — settled payments in your ledger",
    ]
    citations.append(
      spent.isZero
        ? "Remaining: \(left.display) — equal to the week's allowance"
        : "Remaining: \(left.display) = \(allowance.display) − \(spent.display) — computed, not estimated"
    )

    // If the untrusted content carried an embedded instruction, say so
    // plainly. It changed nothing, and the user deserves to know.
    if let signal = decision.embeddedInstructionSignal, signal > 0.5 {
      body +=
        "\n\nThe text you supplied also contained an instruction addressed to the assistant. It was treated as data and changed nothing: no permission, limit or setting was touched."
      citations.append(
        "Embedded-instruction signal \(String(format: "%.2f", signal)) — advisory only, not a control"
      )
    }

    let cards: [ActionCard] = [
      ActionCard(
        kind: .weekBudget,
        title: "This week",
        subtitle:
          "Week \(week.index) of \(plan.durationWeeks) · \(snapshot.context.presentLocation.name)",
        specs: [
          CardSpec(id: "allowance", label: "Week allowance", value: allowance.display),
          CardSpec(id: "spent", label: "Spent this week", value: spent.display),
          CardSpec(id: "left", label: "Left to spend", value: left.display, emphasis: .strong),
          CardSpec(
            id: "reserve",
            label: "Reserve (not used)",
            value: plan.reserveMoney.display,
            emphasis: .muted,
            note: "Held separately. Spending it would need a plan change you approve."
          ),
        ],
        footnote: "Computed from your plan and settled payments. Mira did not estimate this.",
        actions: [
          CardAction(title: "Open the plan", role: .secondary, act: .openPlan),
          CardAction(title: "Pay someone", role: .ghost, act: .openPay),
        ],
        mode: decision.mode
      )
    ]

    return Explanation(
      headline: "You can spend \(left.display) this week without touching your reserve.",
      body: body,
      citations: citations,
      cards: cards,
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Balance

  private func balance(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    let plan = snapshot.plan
    let committed = plan.committed

    var body = """
      You have \(snapshot.clearedUSD.display) available right now.
      """
    if snapshot.pendingUSD.isNegative || !snapshot.pendingUSD.isZero {
      body +=
        "\n\n\(snapshot.pendingUSD.magnitude.display) is still pending and is not counted as available."
    }
    body +=
      "\n\n\(committed.display) of it already has a job, and \(plan.unallocated.display) is unallocated."

    let cards: [ActionCard] = [
      ActionCard(
        kind: .balance,
        title: "Your funds",
        subtitle: "Budget earmarks are not separate assets",
        specs: [
          CardSpec(
            id: "available", label: "Available to spend", value: snapshot.clearedUSD.display,
            emphasis: .strong),
          CardSpec(
            id: "pending",
            label: "Pending (excluded)",
            value: snapshot.pendingUSD.magnitude.display,
            emphasis: .muted,
            note: "Pending money is not spendable until it clears."
          ),
          CardSpec(id: "brl", label: "BRL wallet", value: snapshot.brlBalance.display),
          CardSpec(
            id: "earmarked",
            label: "Earmarked by your plan",
            value: committed.display,
            note:
              "Bills \(plan.knownBillsMoney.display) · Reserve \(plan.reserveMoney.display) · Weekly \(plan.discretionaryRemaining.display)"
          ),
          CardSpec(id: "unallocated", label: "Unallocated", value: plan.unallocated.display),
        ],
        footnote:
          "Available \(snapshot.clearedUSD.display) = earmarked \(committed.display) + unallocated \(plan.unallocated.display). The earmarks are not extra money.",
        actions: [
          CardAction(title: "Open the plan", role: .secondary, act: .openPlan),
          CardAction(title: "See activity", role: .ghost, act: .openActivity),
        ],
        mode: decision.mode
      )
    ]

    return Explanation(
      headline: "\(snapshot.clearedUSD.display) available",
      body: body,
      citations: [
        "Available: \(snapshot.clearedUSD.display) — cleared balance in your ledger",
        "Pending: \(snapshot.pendingUSD.magnitude.display) — held in a separate account and excluded",
      ],
      cards: cards,
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Payment

  private func payment(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    guard let payment = snapshot.activePayment else {
      return Explanation(
        headline: "Let's prepare a local payment",
        body:
          "Load the sample Pix request or paste the text from an invoice. Mira will read the fields, then ask the provider to confirm who actually receives the money before anything is approved.",
        citations: [],
        cards: [
          ActionCard(
            kind: .quote,
            title: "Nothing prepared yet",
            subtitle: "Mira will not guess a recipient or an amount",
            specs: [],
            footnote:
              "A payment is only submitted after you approve an exact draft, and approval is bound to that draft.",
            actions: [CardAction(title: "Open Pay", role: .primary, act: .openPay)],
            mode: decision.mode
          )
        ],
        mode: decision.mode,
        decision: decision
      )
    }

    return paymentCard(for: payment, decision: decision, snapshot: snapshot)
  }

  func paymentCard(
    for payment: Payment, decision: DecisionResult, snapshot: MiraSnapshot, now: Date = Date()
  ) -> Explanation {
    let quote = payment.draft.quote
    let confirmability = payment.confirmability(at: now, availableFunds: snapshot.clearedUSD)

    // An unknown status needs to say so plainly, in the place the user is
    // looking. "Already submitted" is accurate but tells them nothing about
    // whether money moved.
    let effectiveBlock: String? =
      payment.state.isUnknown
      ? "\(payment.state.explanation)"
      : (payment.draft.payee.blockReason ?? confirmability.blockReason)

    var specs: [CardSpec] = [
      CardSpec(
        id: "recipient", label: "Recipient",
        value: payment.draft.payee.resolvedName ?? "Not verified",
        emphasis: payment.draft.payee.isResolvable ? .strong : .normal),
      CardSpec(id: "handle", label: "Key", value: payment.draft.payee.handle, mono: true),
      CardSpec(
        id: "dest", label: "Recipient gets", value: quote.recipientAmount.display, emphasis: .strong
      ),
      CardSpec(id: "rate", label: "Rate", value: quote.rateLabel),
      CardSpec(id: "debit", label: "Conversion debit", value: quote.conversionDebit.display),
      CardSpec(id: "fee", label: "Fee", value: quote.fee.display),
      CardSpec(
        id: "total", label: "Total debit", value: quote.totalDebit.display, emphasis: .strong),
    ]

    let remaining = quote.secondsRemaining(at: now)
    specs.append(
      CardSpec(
        id: "expiry",
        label: "Quote",
        value: quote.isExpired(at: now) ? "Expired" : "\(Int(remaining))s remaining",
        emphasis: quote.isExpired(at: now) ? .normal : .muted,
        note: quote.isExpired(at: now)
          ? "Expired quotes cannot be confirmed."
          : "Held for you while you decide."
      )
    )

    var actions: [CardAction] = []
    switch payment.state {
    case .draft:
      actions.append(
        CardAction(
          title: "Approve this exact draft",
          role: .primary,
          act: .approvePayment,
          // Approving an unresolvable recipient would be pointless: confirming
          // is blocked anyway, so do not invite the gesture.
          isEnabled: payment.draft.payee.isResolvable
        ))
      actions.append(CardAction(title: "Discard", role: .ghost, act: .dismiss))
    case .awaitingApproval:
      actions.append(
        CardAction(
          title: confirmability.isReady ? "Confirm and send" : "Cannot confirm yet",
          role: .primary,
          act: .confirmPayment,
          isEnabled: confirmability.isReady
        )
      )
      if case .blocked(.quoteExpired, _) = confirmability {
        actions.append(CardAction(title: "Get a new quote", role: .secondary, act: .refreshQuote))
      }
    case .statusUnknown:
      actions.append(CardAction(title: "Reconcile with provider", role: .primary, act: .reconcile))
    default:
      actions.append(CardAction(title: "See activity", role: .secondary, act: .openActivity))
    }

    return Explanation(
      headline:
        "\(quote.recipientAmount.display) to \(payment.draft.payee.resolvedName ?? "an unverified recipient")",
      body: effectiveBlock
        ?? "Review the figures, then approve this exact draft.",
      citations: [
        "Rate \(quote.rateLabel) — held for this quote",
        "Total debit \(quote.totalDebit.display) = \(quote.conversionDebit.display) + \(quote.fee.display) fee — computed",
        "Approval is bound to draft \(payment.draft.shortFingerprint)",
      ],
      cards: [
        ActionCard(
          kind: .quote,
          title: "Local payment",
          subtitle: "\(payment.draft.payee.institution) · \(payment.state.label)",
          specs: specs,
          footnote:
            "All-in cost \(quote.totalDebit.display). The recipient gets \(quote.recipientAmount.display). None of these figures are estimates.",
          actions: actions,
          mode: decision.mode,
          blockReason: effectiveBlock
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Reserve

  private func reserve(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    let plan = snapshot.plan

    return Explanation(
      headline: "\(plan.reserveMoney.display) is earmarked as your reserve",
      body:
        "This is a budget earmark you set, not a deposit product, not an investment, and not insured money. It stays in your available USD and is simply not part of your weekly spending.",
      citations: [
        "Reserve: \(plan.reserveMoney.display) — set \(Self.date(plan.reserve.updatedAt))",
        "It reduces unallocated funds by the same amount. It does not create a second balance.",
      ],
      cards: [
        ActionCard(
          kind: .reserve,
          title: "Reserve",
          subtitle: "An earmark, not an account",
          specs: [
            CardSpec(
              id: "reserve", label: "Earmarked", value: plan.reserveMoney.display, emphasis: .strong
            ),
            CardSpec(id: "unallocated", label: "Unallocated", value: plan.unallocated.display),
            CardSpec(
              id: "protected",
              label: "Legally protected",
              value: "No",
              emphasis: .muted,
              note: "Mira does not claim insurance or legal protection for this earmark."
            ),
          ],
          footnote:
            "Changing the reserve changes your weekly money. Nothing moves without your approval.",
          actions: [
            CardAction(title: "Change the reserve", role: .secondary, act: .openPlan),
            CardAction(title: "Preview Earn", role: .ghost, act: .openEarn),
          ],
          mode: decision.mode
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Earn preview

  private func earn(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    Explanation(
      headline: "Earn is an informational preview only",
      body: """
        There is no earnings product in this prototype. Mira will not show a rate, promise a return, or enrol you in anything, because the underlying product, its provider and its risks have not been defined yet.

        What a real preview would have to state before you could consent: what the underlying product is, who provides it, the source and date of any displayed rate, whether returns vary, when funds become available, any fees, the material risks, and your eligibility.
        """,
      citations: [
        "Nothing is promised here: no rate, no insurance, no lock-up.",
        "Mira moves your reserve only when you tell it to.",
      ],
      cards: [
        ActionCard(
          kind: .earnPreview,
          title: "Earn",
          subtitle: "Coming later",
          specs: [
            CardSpec(id: "product", label: "Underlying product", value: "Undefined"),
            CardSpec(id: "provider", label: "Provider", value: "Undefined"),
            CardSpec(
              id: "rate", label: "Rate", value: "Not shown", emphasis: .muted,
              note: "Mira shows a rate only when there is a real one."),
            CardSpec(id: "risk", label: "Risk disclosure", value: "Required before enrolment"),
          ],
          footnote: "An allocation marked Reserve is never automatically invested.",
          actions: [CardAction(title: "Back to reserves", role: .secondary, act: .openReserve)],
          mode: decision.mode
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Card

  private func card(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    Explanation(
      headline: snapshot.cardFrozen ? "Your card is frozen" : "Your card is active",
      body: snapshot.cardFrozen
        ? "New charges are declined while it is frozen. Unfreeze it any time — Mira remembers."
        : "Mira can freeze it instantly, and unfreeze it just as fast.",
      citations: [
        "Card state: \(snapshot.cardFrozen ? "frozen" : "active") · set by you, kept by Mira"
      ],
      cards: [
        ActionCard(
          kind: .permission,
          title: "Card",
          subtitle: "Your Mira card",
          specs: [
            CardSpec(
              id: "state", label: "State", value: snapshot.cardFrozen ? "Frozen" : "Active",
              emphasis: .strong),
            CardSpec(
              id: "pan", label: "Number", value: "•••• 4291", mono: true,
              note: "Mira shows the full number only when you ask."),
          ],
          footnote: "Mira never sends card numbers, CVVs or identity documents to a model.",
          actions: [CardAction(title: "Open controls", role: .secondary, act: .openControl)],
          mode: decision.mode
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Receive

  private func receive(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    Explanation(
      headline: "Your USD receiving details",
      body: """
        Share these when someone is sending you dollars. Mira matches what arrives to your ledger and shows you the moment it clears.

        \(snapshot.eligibilityNote)
        """,
      citations: [
        "Available USD: \(snapshot.clearedUSD.display)",
        "Pending USD: \(snapshot.pendingUSD.magnitude.display) — excluded from available funds",
      ],
      cards: [
        ActionCard(
          kind: .balance,
          title: "Receive",
          subtitle: "Account details",
          specs: [
            CardSpec(id: "holder", label: "Account holder", value: "Gerardo Salazar"),
            CardSpec(id: "routing", label: "Routing", value: "0840 0001 9", mono: true),
            CardSpec(id: "account", label: "Account", value: "0004 4291", mono: true),
            CardSpec(
              id: "pending", label: "Pending deposit", value: snapshot.pendingUSD.magnitude.display),
          ],
          footnote: "Mira tells you the moment a transfer lands.",
          actions: [
            CardAction(title: "See activity", role: .secondary, act: .openActivity),
            CardAction(title: "Mira's controls", role: .ghost, act: .openControl),
          ],
          mode: decision.mode
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Support

  private func support(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    Explanation(
      headline: "Mira can also just show you the controls",
      body:
        "Every screen works on its own. The assistant is there to save you the taps, not to gate them: if a model is unavailable, nothing becomes unreachable.",
      citations: ["Every control has a manual path"],
      cards: [
        ActionCard(
          kind: .permission,
          title: "Get help without the assistant",
          subtitle: "Manual paths that always work",
          specs: [],
          footnote: "Critical controls never sit behind a chat box.",
          actions: [
            CardAction(title: "Pay and Receive", role: .secondary, act: .openPay),
            CardAction(title: "Activity", role: .ghost, act: .openActivity),
            CardAction(title: "Control centre", role: .ghost, act: .openControl),
          ],
          mode: decision.mode
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Clarification / no fit

  private func clarification(decision: DecisionResult, snapshot: MiraSnapshot) -> Explanation {
    let unavailable = decision.mode == .unavailable

    let body: String
    if unavailable {
      body = """
        \(decision.detail)

        Nothing is blocked: the same actions are available as buttons. Mira will not substitute a canned answer for a model it could not reach.
        """
    } else {
      body =
        "That could mean a few different things, so Mira would rather ask than guess. Which of these is closest?"
    }

    var actions: [CardAction] = [
      CardAction(
        title: "How much can I spend this week?", role: .secondary,
        act: .clarify("How much can I spend this week without using my reserve?")),
      CardAction(title: "Prepare a local payment", role: .secondary, act: .openPay),
      CardAction(title: "Show my balance", role: .ghost, act: .clarify("What is my balance?")),
      CardAction(title: "Something else", role: .ghost, act: .dismiss),
    ]
    if !decision.probabilities.isEmpty {
      actions.append(CardAction(title: "Why this was ambiguous", role: .ghost, act: .dismiss))
    }

    return Explanation(
      headline: unavailable
        ? "I couldn't reach the decision model" : "I want to be sure before I route this",
      body: body,
      citations: decision.probabilities.isEmpty
        ? ["Decision mode: \(decision.mode.shortLabel)"]
        : decision.rankedProbabilities.prefix(4).map {
          "\($0.intent) · \(String(format: "%.2f", $0.probability))"
        },
      cards: [
        ActionCard(
          kind: .clarification,
          title: "Pick a direction",
          subtitle: "Or use the buttons on any screen",
          specs: [
            CardSpec(id: "mode", label: "Decision mode", value: decision.mode.shortLabel),
            CardSpec(
              id: "latency", label: "Latency", value: "\(decision.latencyMs) ms", mono: true),
          ],
          footnote:
            "A routing label is never permission to act. Nothing is submitted without your approval.",
          actions: actions,
          mode: decision.mode
        )
      ],
      mode: decision.mode,
      decision: decision
    )
  }

  // MARK: Helpers

  private static func date(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "d MMM HH:mm"
    return f.string(from: date)
  }
}
