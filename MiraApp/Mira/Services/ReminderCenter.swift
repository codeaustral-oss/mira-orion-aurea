import Foundation
import Observation
import UserNotifications

// MARK: - The app's one door to the notification center
//
// Everything here is local: a reminder is arithmetic on a record the app
// already holds, and it is scheduled with `UNUserNotificationCenter`. There is
// no APNs certificate and nothing is pushed. The center keeps its own house in
// order — a re-plan replaces the same identifiers, drops anything the records
// no longer justify, and never leaves more pending than `Reminders.cap`.
//
// Permission is asked once, the first time a reminder is actually wanted, and
// only after the app has said in its own words what will arrive (the root view
// shows that explanation before the system prompt).

@MainActor
@Observable
final class ReminderCenter: NSObject, UNUserNotificationCenterDelegate {
  static let shared = ReminderCenter()
  /// Every identifier this app owns starts here, so a sweep can tell its own
  /// pending reminders from anything else and never touches another app's.
  static let identifierPrefix = "mira.reminder."

  /// True when a first reminder wants the plain explanation before the system
  /// prompt. `MiraRoot` presents it and answers it.
  private(set) var needsExplanation = false

  @ObservationIgnored private let center = UNUserNotificationCenter.current()
  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private let explainedKey = "mira.reminders.explained"

  override init() {
    super.init()
    // Banners are shown while the app is open too: a wake may land a line the
    // person asked for, and it must not vanish merely because the app is up.
    center.delegate = self
  }

  // MARK: Permission

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  /// Make the pending reminders exactly what the records justify, asking for
  /// permission first when the moment calls for it and the person has not been
  /// asked. An empty plan needs no permission: it only clears.
  func refresh(_ desired: [MiraReminder], askIfNeeded: Bool = true) async {
    guard !desired.isEmpty else {
      await apply([])
      return
    }
    switch await authorizationStatus() {
    case .notDetermined:
      guard askIfNeeded, !needsExplanation, !defaults.bool(forKey: explainedKey) else { return }
      needsExplanation = true
    case .authorized, .provisional, .ephemeral:
      await apply(desired)
    default:
      // Denied. Nothing can arrive, and the app does not pretend otherwise.
      await apply([])
    }
  }

  /// The person tapped "Allow reminders" on the explanation. Asking is not
  /// scheduling: the caller re-plans and the granted status lets it apply.
  func confirmExplanation() async {
    needsExplanation = false
    defaults.set(true, forKey: explainedKey)
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  /// The person tapped "Not now". The app never asks again in this install;
  /// the Controls switch is where they can change their mind.
  func declineExplanation() {
    needsExplanation = false
    defaults.set(true, forKey: explainedKey)
  }

  // MARK: Scheduling

  /// Make the pending scheduled reminders exactly this plan: replacements keep
  /// their identifiers, stale ones are removed, and the cap is applied again
  /// here so nothing can slip past it.
  func apply(_ desired: [MiraReminder]) async {
    let wanted = Reminders.capped(desired)
    let wantedIDs = Set(wanted.map(\.id))
    let pending = await center.pendingNotificationRequests()
    let stale = pending.map(\.identifier).filter {
      $0.hasPrefix(Self.identifierPrefix) && !wantedIDs.contains($0)
    }
    if !stale.isEmpty {
      center.removePendingNotificationRequests(withIdentifiers: stale)
    }
    for reminder in wanted {
      try? await center.add(request(for: reminder))
    }
  }

  /// Something true now rather than on a schedule: a watch that checked while
  /// the app was closed, or a run that finished. Delivered at once, and it can
  /// retire the scheduled line for the same subject so one thing is announced
  /// once.
  func post(_ reminder: MiraReminder, canceling ids: [String] = []) async {
    if !ids.isEmpty {
      center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    try? await center.add(request(for: reminder, immediate: true))
  }

  /// Cancel exactly these identifiers. Every scheduled item has one, so every
  /// scheduled item can be taken back.
  func cancel(_ ids: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }

  // MARK: Requests

  private func request(for reminder: MiraReminder, immediate: Bool = false) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = reminder.title
    content.body = reminder.body
    content.sound = .default
    content.threadIdentifier = "mira.reminders"
    content.userInfo = ["miraReminder": reminder.kind.rawValue]

    let trigger: UNNotificationTrigger?
    if immediate {
      trigger = nil
    } else {
      let components = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: reminder.fireDate)
      trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
    return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
  }

  // MARK: Foreground

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }
}
