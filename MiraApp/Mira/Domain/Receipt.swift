import Foundation

// MARK: - Documents
//
// A confirmation is a document, not a sentence. An order is a receipt, a swap
// is a slip, a trip is an itinerary, a table is a reservation — and each one is
// rendered as itself: paper, mono type, dotted rules, a reference you could
// read out. Facts only; the sentence is what Mira says around it.

struct ReceiptLine: Sendable, Equatable, Hashable {
  var label: String
  var value: String
  /// A system symbol for the kind of thing this row is (a plane, a bag, a tag).
  var icon: String? = nil
  /// A service whose own mark should be drawn instead (Netflix, Notion, …).
  var service: String? = nil

  init(label: String, value: String, icon: String? = nil, service: String? = nil) {
    self.label = label
    self.value = value
    self.icon = icon
    self.service = service
  }
}

/// An order, with the parcel's progress through the steps every parcel takes.
///
/// The steps are the app's own simulated logistics — the same honesty rule as
/// the ledger: in the demo they are as real as the figures, and each look moves
/// the parcel one step rather than looping.
struct PlacedOrder: Sendable, Equatable, Codable {
  var reference: String
  var item: String
  var merchant: String?
  var carrier: String = "Mira Logistics"
  var trackingNumber: String
  var step: Int = 0

  static let steps = ["Label created", "Picked up", "In transit", "Out for delivery", "Delivered"]

  init(reference: String, item: String, merchant: String?) {
    self.reference = reference
    self.item = item
    self.merchant = merchant
    // A number a person could read out, derived from the order so it is stable.
    let digits = reference.filter(\.isNumber)
    self.trackingNumber = "ML\(digits.suffix(6))BR"
    self.step = 0
  }

  var isDelivered: Bool { step >= Self.steps.count - 1 }
  var status: String { Self.steps[min(step, Self.steps.count - 1)] }

  /// The item as a title, not as a query: "cat food" becomes "Cat food". The
  /// tracking card titles the thing that is moving.
  var displayItem: String {
    let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = clean.first else { return "Your order" }
    return String(first).uppercased() + clean.dropFirst()
  }

  /// The arrival promise. The demo's tracking moves one step per look and can
  /// deliver within the same minute, so it never promises a five-day window the
  /// tracking slip would contradict.
  var eta: String { isDelivered ? "Delivered" : "Today" }
  var scan: String { isDelivered ? "Delivered — front desk" : "Florianópolis, SC" }

  /// One look, one step — never past delivered.
  func advanced() -> PlacedOrder {
    var next = self
    next.step = min(step + 1, Self.steps.count - 1)
    return next
  }

  var statusLine: String {
    switch status {
    case "Label created": return "\(displayItem) — the label is made and it is waiting for pickup."
    case "Picked up": return "\(displayItem) has been picked up."
    case "In transit": return "\(displayItem) is on its way."
    case "Out for delivery": return "\(displayItem) is out for delivery today."
    default: return "\(displayItem) was delivered."
    }
  }

  /// The receipt's arrival line, said in the same terms as the tracking slip.
  static let arrivalFootnote = "Arrives today — ask me to track it. Nothing else is charged to this card."
}

struct ReceiptSpec: Sendable, Equatable {
  enum Kind: String, Sendable {
    /// Something was bought and paid for.
    case purchase
    /// Money changed currency.
    case swap
    /// A trip, prepared and not booked.
    case itinerary
    /// A table, prepared and not held.
    case reservation
    /// A parcel, with its tracking.
    case tracking
    /// A prepared order for a security. Prepared, never executed here.
    case order
    /// The recurring charges, and what stopping some would save.
    case savings
    /// The offers running, and what they have earned so far.
    case offers
    /// The account's capacity tier, and the facts that earned it.
    case capacity
    /// A working note from the money desk: findings, a plan, a prepared ask.
    case brief
  }

  var kind: Kind
  /// A system symbol for the document's own badge (a plane, a bag, a shield).
  var symbol: String? = nil
  /// The document's own heading: "Order M-53338", "Swap EUR → USD".
  var title: String
  /// One line under the heading: what it is, in a few words.
  var subtitle: String?
  var lines: [ReceiptLine]
  /// The emphasised row: what was paid, or what arrives.
  var total: ReceiptLine?
  /// A reference a person could read out.
  var reference: String?
  /// The honest small print: arrival, or what has not happened yet.
  var footnote: String?
  var date: Date

  // MARK: Builders

  /// A purchase. Every field is one the checkout actually established; nothing
  /// is listed that the app did not do.
  static func purchase(
    item: String,
    merchant: String?,
    address: String?,
    card: CardMock?,
    amount: Money?,
    reference: String,
    cashback: String? = nil,
    date: Date = Date()
  ) -> ReceiptSpec {
    var lines: [ReceiptLine] = [ReceiptLine(label: "Item", value: item)]
    if let merchant { lines.append(ReceiptLine(label: "Merchant", value: merchant)) }
    if let address { lines.append(ReceiptLine(label: "Deliver to", value: address)) }
    if let card { lines.append(ReceiptLine(label: "Paid with", value: "•••• \(card.last4)")) }
    if let cashback { lines.append(ReceiptLine(label: "Cashback", value: cashback)) }
    return ReceiptSpec(
      kind: .purchase,
      symbol: "bag",
      title: "Order \(reference)",
      subtitle: merchant,
      lines: lines,
      total: amount.map { ReceiptLine(label: "Total", value: $0.display) },
      reference: reference,
      footnote: PlacedOrder.arrivalFootnote,
      date: date)
  }

  /// A working note: a list of findings, a plan, a script. The generic document
  /// every money-desk answer ends in, so each one reads the same way.
  static func brief(
    badge: String,
    symbol: String? = nil,
    title: String,
    subtitle: String? = nil,
    lines: [ReceiptLine],
    total: ReceiptLine? = nil,
    footnote: String? = nil,
    date: Date = Date()
  ) -> ReceiptSpec {
    ReceiptSpec(
      kind: .brief, symbol: symbol, title: title, subtitle: subtitle, lines: lines, total: total,
      reference: badge, footnote: footnote, date: date)
  }

  /// The offers, as a document: what is running, where and when it applies,
  /// who funds it, and what it has earned so far — with the issuer's side
  /// stated on the same page.
  static func offers(_ entries: [CashbackEntry], now: Date = Date()) -> ReceiptSpec? {
    let running = Offers.running(now: now)
    guard !running.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM"
    var lines: [ReceiptLine] = running.prefix(5).map { offer in
      var conditions: [String] = [offer.funding.label]
      if offer.days != nil { conditions.append("weekends") }
      if offer.channel != .any { conditions.append(offer.channel.label.lowercased()) }
      if let cap = offer.capMinor {
        let currency = Asset.all.first { $0.code == offer.currencyCode } ?? .usd
        conditions.append("cap \(Money(minorUnits: cap, currency: currency).display)")
      }
      if let expiresAt = offer.expiresAt { conditions.append("ends \(formatter.string(from: expiresAt))") }
      return ReceiptLine(label: offer.title, value: conditions.joined(separator: " · "))
    }
    let summary = Offers.summary(entries, now: now)
    let issuer = Offers.issuerSummary(entries, now: now)
    // Who paid is a line of its own, not small print: the merchant's share and
    // the issuer's share of everything that came back this month.
    if let issuer {
      lines.append(ReceiptLine(label: "From merchants", value: issuer.merchantFunded.display))
      lines.append(ReceiptLine(label: "From Mira", value: issuer.issuerFunded.display))
    }
    // The largest running offer — highest rate, first listed on a tie — has its
    // expiry named, so the biggest thing on the page has a date.
    var largest: CardOffer?
    for offer in running where offer.rate > (largest?.rate ?? 0) { largest = offer }
    if let largest, let expiresAt = largest.expiresAt {
      lines.append(
        ReceiptLine(
          label: "Biggest offer ends",
          value: "\(formatter.string(from: expiresAt)) · \(largest.title)"))
    }
    return ReceiptSpec(
      kind: .offers,
      symbol: "tag",
      title: summary.map { "\($0.credited.display) back this month" } ?? "Offers running",
      subtitle: summary.map { "\($0.pending.display) still pending" },
      lines: lines,
      total: issuer.map { ReceiptLine(label: "Total back", value: $0.cost.display) },
      reference: nil,
      footnote: issuer.map {
        "\($0.redemptions) redemption\($0.redemptions == 1 ? "" : "s") this month."
      },
      date: now)
  }

  /// The subscription list as a document: each charge, the monthly and yearly
  /// totals, and the best few to look at — with the saving stated, not implied.
  static func savings(_ subscriptions: [Subscription], date: Date = Date()) -> ReceiptSpec? {
    guard let savings = Subscriptions.savings(subscriptions) else { return nil }
    let active = subscriptions.filter { !$0.cancelled }
    let nextFormatter = DateFormatter()
    nextFormatter.dateFormat = "d MMM"
    let lines: [ReceiptLine] = active
      .sorted { $0.yearly.minorUnits > $1.yearly.minorUnits }
      .map { subscription in
        // A day number alone ("next 26") says nothing about which month. The
        // next charge is a date, computed from the app's own clock.
        let next = subscription.nextChargeDate(from: date).map {
          " · next charge \(nextFormatter.string(from: $0))"
        } ?? ""
        // Each row wears the service's own mark, so the list is recognised
        // before it is read.
        return ReceiptLine(
          label: subscription.name, value: "\(subscription.amount.display)\(next)",
          service: subscription.name)
      }
    return ReceiptSpec(
      kind: .savings,
      symbol: "arrow.triangle.2.circlepath",
      title: "\(savings.count) subscriptions",
      subtitle: "Every month, quietly",
      lines: lines,
      total: ReceiptLine(label: "A year", value: savings.yearly.display),
      reference: nil,
      footnote: "Cancelling the three dearest would save \(Money(minorUnits: savings.top(3).reduce(Int64(0)) { $0 + $1.yearly.minorUnits }, currency: savings.monthly.currency).display) a year. Nothing is cancelled until you say so.",
      date: date)
  }

  /// The account's tier: what it lifts, and the facts that earned it — each
  /// fact carrying what it contributed, so the terms read as arithmetic.
  static func capacity(_ assessment: Capacity.Assessment, date: Date = Date()) -> ReceiptSpec {
    var lines: [ReceiptLine] = [
      ReceiptLine(label: "FX fee", value: assessment.tier.fxFeeLabel),
      ReceiptLine(label: "Transfer fee", value: assessment.tier.transferFeeLabel),
      ReceiptLine(
        label: "Standing approval",
        value: "\(assessment.tier.standingLimit.display) per order"),
      ReceiptLine(label: "Cashback base", value: assessment.tier.cashbackLabel),
    ]
    lines += assessment.reasons.map {
      ReceiptLine(label: $0.fact, value: "+\($0.points) · \($0.detail)")
    }
    return ReceiptSpec(
      kind: .capacity,
      symbol: "increase",
      title: assessment.tier.name,
      subtitle: "The account's terms, from its own facts",
      lines: lines,
      total: assessment.tier.next.map { ReceiptLine(label: "Next tier", value: $0.name) },
      reference: nil,
      footnote: assessment.nextLine,
      date: date)
  }

  /// A prepared order: ticker, size, venue, the quoted price, an estimate.
  static func order(task: AgentTask) -> ReceiptSpec? {
    let slots = task.slots
    guard let symbol = slots["symbol"], !symbol.isEmpty else { return nil }
    let top = task.options.first
    var lines: [ReceiptLine] = []
    if let quantity = slots["quantity"] { lines.append(ReceiptLine(label: "Size", value: quantity)) }
    if let amount = slots["amount"] { lines.append(ReceiptLine(label: "Amount", value: amount)) }
    if let venue = top?.name { lines.append(ReceiptLine(label: "Venue", value: venue)) }
    if let quote = top?.priceNote, !quote.isEmpty { lines.append(ReceiptLine(label: "Quoted", value: quote)) }
    if let type = slots["orderType"] { lines.append(ReceiptLine(label: "Order", value: type.capitalized)) }

    // An estimate only when the page stated a price and a size is known: the
    // arithmetic is the app's, and the label says whose sum it is.
    var estimate: ReceiptLine?
    let shares = slots["quantity"]
      .flatMap { value in value.split(separator: " ").first.flatMap { Int($0) } }
    if let shares, let price = CheckoutFlow.amount(from: top?.priceNote) {
      let total = Money(minorUnits: price.minorUnits * Int64(shares), currency: price.currency)
      estimate = ReceiptLine(label: "Estimate", value: total.display)
    }

    return ReceiptSpec(
      kind: .order,
      symbol: "chart.line.uptrend.xyaxis",
      title: symbol,
      subtitle: "Order preparation",
      lines: lines,
      total: estimate,
      reference: nil,
      footnote: "Prepared, not executed. The broker page below is where the order is placed.",
      date: task.updatedAt)
  }

  /// A parcel: carrier, number, state, last scan — the thing a person checks.
  /// Titled by the thing that is moving, never by the raw search query.
  static func tracking(_ order: PlacedOrder) -> ReceiptSpec {
    ReceiptSpec(
      kind: .tracking,
      symbol: "shippingbox",
      title: order.displayItem,
      subtitle: order.merchant,
      lines: [
        ReceiptLine(label: "Carrier", value: order.carrier),
        ReceiptLine(label: "Tracking", value: order.trackingNumber),
        ReceiptLine(label: "Status", value: order.status),
        ReceiptLine(label: "Last scan", value: order.scan),
        ReceiptLine(label: "ETA", value: order.eta),
      ],
      total: nil,
      reference: order.reference,
      footnote: order.isDelivered
        ? "Delivered. Nothing else is charged to this card."
        : "Ask me to track it again and the parcel moves on.",
      date: Date())
  }

  /// A renewal ask, as the document the answer promises: what is being asked
  /// for, of whom, by when, and the exact words. Nothing is sent anywhere.
  static func negotiation(_ ask: Negotiation.Ask) -> ReceiptSpec {
    var lines: [ReceiptLine] = [
      ReceiptLine(label: "You pay", value: ask.bill.monthly.display),
      ReceiptLine(label: "Competitor", value: "\(ask.bill.competitorMonthly.display) · \(ask.bill.competitor)"),
      ReceiptLine(label: "Send by", value: ask.deadline),
      ReceiptLine(label: "Prepared for", value: "\(ask.bill.name) retention"),
    ]
    lines += ask.script.map { ReceiptLine(label: "Say", value: $0) }
    return ReceiptSpec(
      kind: .brief,
      symbol: "phone.arrow.up.right",
      title: ask.bill.name,
      subtitle: "Renewal ask, prepared",
      lines: lines,
      total: ReceiptLine(label: "Ask for", value: ask.target.display),
      reference: "NEGOTIATION",
      footnote: "Nothing has been sent. You make the call or send it — the app has no line to the provider.",
      date: Date())
  }

  /// A swap that has posted: what left, what arrived, at what rate.
  static func swap(_ quote: SwapQuote, reference: String, date: Date = Date()) -> ReceiptSpec {
    ReceiptSpec(
      kind: .swap,
      symbol: "arrow.2.squarepath",
      title: "Swap \(quote.from.code) → \(quote.to.code)",
      subtitle: nil,
      lines: [
        ReceiptLine(label: "You paid", value: quote.totalDebit.display),
        ReceiptLine(label: "Rate", value: quote.rateLabel),
        ReceiptLine(label: "Fee", value: quote.fee.display),
      ],
      total: ReceiptLine(label: "You received", value: quote.toAmount.display),
      reference: reference,
      footnote: "In your activity. The rate is the one the quote was priced at.",
      date: date)
  }

  /// A trip, from the task's own slots: route, dates, travellers.
  static func itinerary(task: AgentTask) -> ReceiptSpec? {
    let slots = task.slots
    let destination = slots["destination"]
    let origin = slots["origin"]
    guard destination != nil || origin != nil else { return nil }
    let route = [origin, destination].compactMap { $0 }.joined(separator: "  →  ")
    var lines: [ReceiptLine] = []
    if let dates = slots["dates"] { lines.append(ReceiptLine(label: "Dates", value: dates)) }
    if let travelers = slots["travelers"] { lines.append(ReceiptLine(label: "Travellers", value: travelers)) }
    if let budget = slots["budget"] { lines.append(ReceiptLine(label: "Budget", value: budget)) }
    return ReceiptSpec(
      kind: .itinerary,
      symbol: "airplane.departure",
      title: route.isEmpty ? task.displayTitle : route,
      subtitle: "Prepared itinerary",
      lines: lines,
      total: nil,
      reference: nil,
      footnote: "Not booked. Open a carrier or booking page below to complete it.",
      date: task.updatedAt)
  }

  /// A table, prepared. The reservation is on the venue's page, not here.
  static func reservation(task: AgentTask) -> ReceiptSpec? {
    let slots = task.slots
    let venue = slots["location"]
    guard venue != nil || slots["date"] != nil || slots["partySize"] != nil else { return nil }
    var lines: [ReceiptLine] = []
    if let date = slots["date"] { lines.append(ReceiptLine(label: "When", value: date)) }
    if let time = slots["time"] { lines.append(ReceiptLine(label: "Time", value: time)) }
    if let party = slots["partySize"] { lines.append(ReceiptLine(label: "Party", value: party)) }
    if let cuisine = slots["cuisine"] { lines.append(ReceiptLine(label: "Kitchen", value: cuisine)) }
    return ReceiptSpec(
      kind: .reservation,
      symbol: "fork.knife",
      title: venue ?? task.displayTitle,
      subtitle: "Reservation preparation",
      lines: lines,
      total: nil,
      reference: nil,
      footnote: "No table is held. The reservation link below is where it is made.",
      date: task.updatedAt)
  }
}
