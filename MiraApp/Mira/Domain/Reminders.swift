import Foundation

// MARK: - Reminders
//
// The things the app can say when it is not open, decided from records it
// already holds: a renewal nudge on the charge day, a price-claim deadline
// three days before the window closes, and — only when the proxy is unreachable
// at the moment the plan is made — a quiet line about a watch whose check could
// not run.
//
// All of it is arithmetic on dates. There is no network here, no model, and no
// second copy of the charge arithmetic: the date a subscription charges next
// comes from `Subscription.nextChargeDate`, the same function
// `Subscriptions.chargingSoon` reads. Planning is a pure function so the
// schedule can be tested without a notification center or a permission prompt.

/// One reminder the app would hand to iOS.
///
/// `id` is stable for the record it belongs to, so re-planning replaces the
/// same slot instead of adding a duplicate, and cancelling one id cancels that
/// record's reminder and nothing else.
struct MiraReminder: Identifiable, Sendable, Equatable {
  enum Kind: String, Sendable, Equatable {
    /// "Your subscription charges tomorrow."
    case renewal
    /// "The price window closes in three days."
    case claimDeadline
    /// "I could not check the watch — open Mira." Scheduled only while the
    /// proxy is unreachable, so it is never a guess about a check that ran.
    case watchMiss
    /// A check that did run while the app was closed, found by a background wake.
    case watchCheck
    /// A run that finished while the app was closed.
    case taskFinished
  }

  let kind: Kind
  let id: String
  let fireDate: Date
  let title: String
  let body: String

  init(kind: Kind, key: String, fireDate: Date, title: String, body: String) {
    self.kind = kind
    self.id = "mira.reminder.\(kind.rawValue).\(key)"
    self.fireDate = fireDate
    self.title = title
    self.body = body
  }
}

enum Reminders {
  /// iOS keeps the soonest 64 pending notifications and silently discards the
  /// rest. Twenty is the cap this app holds itself to, so what it schedules is
  /// what it can account for and cancel.
  static let cap = 20

  /// The hour a scheduled nudge lands: nine in the morning.
  static let hour = 9

  /// The server sends watch times as milliseconds since 1970.
  static func watchDate(_ milliseconds: Double?) -> Date? {
    guard let milliseconds, milliseconds > 0 else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  /// "today" / "tomorrow" / "in N days" — the app's own words, the same ones
  /// `Subscription.chargeIn` uses.
  static func dayWord(_ date: Date, from now: Date, calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
    ).day ?? 0
    switch days {
    case ...0: return "today"
    case 1: return "tomorrow"
    default: return "in \(days) days"
    }
  }

  /// The name a watch is spoken about by, without the card's "Watching:" label.
  static func watchName(for task: AgentTask) -> String {
    var name = task.displayTitle
    if let colon = name.firstIndex(of: ":") {
      let head = name[..<colon].trimmingCharacters(in: .whitespaces)
      if head.caseInsensitiveCompare("watching") == .orderedSame {
        name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      }
    }
    return name.isEmpty ? "the watch" : name
  }

  // MARK: Renewals

  /// A nudge on the charge day at 09:00, for every active subscription whose
  /// day the app knows. A charge whose nine o'clock is already behind us rolls
  /// to the record's next charge, so nothing is ever scheduled in the past.
  static func renewals(
    _ subscriptions: [Subscription], from now: Date = Date(), calendar: Calendar = .current
  ) -> [MiraReminder] {
    subscriptions.compactMap { subscription in
      guard !subscription.cancelled, subscription.nextChargeDay != nil else { return nil }
      guard let charge = subscription.nextChargeDate(from: now, calendar: calendar) else { return nil }
      guard var fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: charge) else {
        return nil
      }
      if fire <= now {
        guard
          let next = subscription.nextChargeDate(
            from: now.addingTimeInterval(24 * 3600), calendar: calendar),
          let later = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: next)
        else { return nil }
        fire = later
      }
      let card = subscription.cardLast4.map { " on the card ending \($0)" } ?? ""
      return MiraReminder(
        kind: .renewal,
        key: subscription.id.uuidString,
        fireDate: fire,
        title: "\(subscription.name) charges \(dayWord(fire, from: now, calendar: calendar))",
        body: "\(subscription.amount.display)\(card). Open Mira to cancel or keep it."
      )
    }
  }

  // MARK: Claims

  /// Three days before a price-claim window closes, for a claim that is still
  /// open. A filed claim has no deadline left, and a closed window is not a
  /// reminder — it is history.
  static func claimDeadlines(
    _ claims: [PriceClaim], from now: Date = Date(), calendar: Calendar = .current
  ) -> [MiraReminder] {
    claims.compactMap { claim in
      guard claim.stage == .watching || claim.stage == .claimPrepared else { return nil }
      let windowEnd = claim.windowEnd(calendar: calendar)
      guard windowEnd > now else { return nil }
      let threeDaysBefore = calendar.date(byAdding: .day, value: -3, to: windowEnd) ?? windowEnd
      guard let atNine = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: threeDaysBefore)
      else { return nil }
      // Inside the last three days the reminder is due now, not in the past.
      let fire = atNine > now ? atNine : now.addingTimeInterval(60)
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.dateFormat = "d MMMM"
      let closes = formatter.string(from: windowEnd)
      return MiraReminder(
        kind: .claimDeadline,
        key: claim.id.uuidString,
        fireDate: fire,
        title: "\(claim.item) price window closes \(closes)",
        body: "The \(claim.windowDays)-day window closes \(closes). Open Mira to file the claim before it does."
      )
    }
  }

  // MARK: Watches

  /// The identifier the scheduled miss for a watch uses. The background wake
  /// cancels exactly this when it posts the miss itself, so one check is never
  /// announced twice.
  static func watchMissID(for taskId: String) -> String {
    "mira.reminder.watchMiss.\(taskId)"
  }

  /// The quiet line for a watch whose check could not run. Built for a specific
  /// fire date so the scheduled version (at the next check) and the background
  /// wake's immediate version (when the check came and the proxy was down) say
  /// exactly the same thing.
  static func watchMissReminder(for task: AgentTask, fireDate: Date) -> MiraReminder? {
    guard let watch = task.watch, watch.active else { return nil }
    let name = watchName(for: task)
    return MiraReminder(
      kind: .watchMiss,
      key: task.id,
      fireDate: fireDate,
      title: "I could not check \(name)",
      body: "The proxy was not reachable at the check time. Open Mira to try it again."
    )
  }

  /// Watch-miss reminders for a plan. They exist only when the proxy really is
  /// unreachable at the moment the plan is made: with a reachable proxy the
  /// check itself happens, and a scheduled apology would be a lie.
  static func watchMisses(
    _ tasks: [AgentTask], proxyReachable: Bool, now: Date = Date()
  ) -> [MiraReminder] {
    guard !proxyReachable else { return [] }
    return tasks.compactMap { task in
      guard let watch = task.watch, watch.active,
        let next = watchDate(watch.nextCheckAt), next > now
      else { return nil }
      return watchMissReminder(for: task, fireDate: next)
    }
  }

  // MARK: The plan

  /// Everything the app would schedule right now, soonest first and capped.
  /// `enabled` is the person's own switch: off means nothing is scheduled and
  /// anything already pending is dropped by the caller.
  static func plan(
    subscriptions: [Subscription],
    claims: [PriceClaim],
    tasks: [AgentTask],
    proxyReachable: Bool,
    enabled: Bool = true,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [MiraReminder] {
    guard enabled else { return [] }
    return capped(
      renewals(subscriptions, from: now, calendar: calendar)
        + claimDeadlines(claims, from: now, calendar: calendar)
        + watchMisses(tasks, proxyReachable: proxyReachable, now: now))
  }

  /// The cap rule: keep the soonest-firing reminders, exactly the way iOS keeps
  /// the soonest 64. Anything past the cap is dropped rather than scheduled, so
  /// nothing sits on the device that the app cannot name and cancel.
  static func capped(_ reminders: [MiraReminder]) -> [MiraReminder] {
    Array(
      reminders
        .sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        .prefix(cap))
  }
}
