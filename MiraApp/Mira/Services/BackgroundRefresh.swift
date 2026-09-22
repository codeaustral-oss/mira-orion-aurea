import BackgroundTasks
import Foundation

// MARK: - What a wake should say
//
// Without an APNs certificate there is no push that tells the app a watch
// checked or a run finished. A background wake is the substitute: when iOS
// chooses to grant one, the app asks the proxy once, compares the answer with
// the last reading the person was actually told about, and speaks only when
// the two differ.
//
// The comparison is a pure function on two records, so what counts as "news"
// is testable without a scheduler, a network or a clock.

/// The reading the person was last told about, and the change detector over it.
enum TaskNotice {
  /// One comparable string per task. A watch's identity is its last check; a
  /// run's is its status. Two readings with the same fingerprint are the same
  /// news, and the person is not told twice.
  static func fingerprint(_ task: AgentTask) -> String {
    if let watch = task.watch {
      return [
        "watch",
        String(watch.lastCheckAt ?? -1),
        String(watch.checkCount),
        String(watch.lastOk),
        watch.lastSummary,
        watch.lastPrice ?? "",
      ].joined(separator: "|")
    }
    return "run|\(task.status.rawValue)"
  }

  /// Which fetched readings are worth telling: a watch whose check differs
  /// from the last one the person was told about, and a run that finished
  /// after they left. Still running is not news, and a task the app has never
  /// told them about (an older record) is not news either.
  static func changed(_ tasks: [AgentTask], told: [String: String]) -> [AgentTask] {
    tasks.filter { task in
      guard let previous = told[task.id] else { return false }
      let current = fingerprint(task)
      if task.watch != nil { return current != previous }
      return task.status.isTerminal && current != previous
    }
  }

  /// One task per wake: a live watch, or a run that could still finish,
  /// newest first, preferring the conversation the app was left on. The
  /// refresh budget is one request, so the plan is one candidate; the next
  /// wake takes the next one.
  static func candidate(_ tasks: [AgentTask], activeThreadId: UUID?) -> AgentTask? {
    let interesting = tasks.filter { task in
      if let watch = task.watch { return watch.active }
      return task.status.isActive || task.needsHydration
    }
    let ordered = interesting.sorted { a, b in
      let aHere = a.threadId != nil && a.threadId == activeThreadId
      let bHere = b.threadId != nil && b.threadId == activeThreadId
      if aHere != bHere { return aHere }
      if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
      return a.id < b.id
    }
    return ordered.first
  }

  /// The notification for a changed reading, in the app's own voice: no
  /// urgency words, no exclamation marks, and always one way in — open Mira.
  static func notice(for task: AgentTask) -> MiraReminder {
    let name = task.displayTitle
    if let watch = task.watch {
      let summary = watch.lastSummary.trimmingCharacters(in: .whitespacesAndNewlines)
      if watch.lastOk {
        return MiraReminder(
          kind: .watchCheck,
          key: "\(task.id).\(watch.checkCount)",
          fireDate: Date(),
          title: "A new check on \(Reminders.watchName(for: task))",
          body: summary.isEmpty ? "Open Mira to see what changed." : summary)
      }
      return MiraReminder(
        kind: .watchCheck,
        key: "\(task.id).\(watch.checkCount)",
        fireDate: Date(),
        title: "A check on \(Reminders.watchName(for: task)) could not run",
        body: "Open Mira to see the last reading and try again.")
    }

    let summary = task.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    switch task.status {
    case .failed:
      let why = (task.error ?? summary).trimmingCharacters(in: .whitespacesAndNewlines)
      return MiraReminder(
        kind: .taskFinished, key: task.id, fireDate: Date(),
        title: "\(name) could not finish",
        body: why.isEmpty ? "Open Mira to see what happened." : why)
    case .needsInput:
      let question = (task.question ?? summary).trimmingCharacters(in: .whitespacesAndNewlines)
      return MiraReminder(
        kind: .taskFinished, key: task.id, fireDate: Date(),
        title: "\(name) needs your input",
        body: question.isEmpty ? "Open Mira to answer it." : question)
    default:
      return MiraReminder(
        kind: .taskFinished, key: task.id, fireDate: Date(),
        title: "\(name) is ready",
        body: summary.isEmpty ? "Open Mira to read it." : summary)
    }
  }
}

// MARK: - What the person was told
//
// A small durable record beside the task store: the fingerprint of each task's
// last announced reading, and, per watch, the check window already apologised
// for. Without it a wake could not tell a change from the same reading twice.

struct ReminderNoticePayload: Codable, Sendable {
  var version: Int = 1
  var told: [String: String] = [:]
  /// Watch task id → the nextCheckAt already reported as missed.
  var missed: [String: Double] = [:]
}

final class ReminderNoticeStore {
  private let path: URL

  init(path: URL? = nil) {
    self.path = path ?? ReminderNoticeStore.defaultPath()
  }

  static func defaultPath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Mira", isDirectory: true)
      .appendingPathComponent("notices.json")
  }

  func load() -> ReminderNoticePayload {
    do {
      let data = try Data(contentsOf: path)
      return try JSONDecoder().decode(ReminderNoticePayload.self, from: data)
    } catch {
      return ReminderNoticePayload()
    }
  }

  func save(_ payload: ReminderNoticePayload) {
    do {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(payload)
      let tmp = path.appendingPathExtension("tmp")
      try data.write(to: tmp, options: .atomic)
      _ = try? FileManager.default.removeItem(at: path)
      try FileManager.default.moveItem(at: tmp, to: path)
    } catch {
      // Losing this write only costs a duplicate or a missed line, never the
      // task records themselves.
    }
  }

  /// Mark every reading the app currently holds as something the person has
  /// already been told. Called as the app goes to the background, so the next
  /// wake only speaks about what happened after they left.
  func markTold(_ tasks: [AgentTask]) {
    guard !tasks.isEmpty else { return }
    var payload = load()
    for task in tasks { payload.told[task.id] = TaskNotice.fingerprint(task) }
    save(payload)
  }
}

// MARK: - The wake itself

/// Registers and runs the one background refresh the app asks iOS for.
///
/// iOS decides whether and when the wake happens; nothing here assumes it
/// will. One request, a few seconds of patience, and a notification only for a
/// genuine change.
enum MiraBackgroundRefresh {
  /// Must match `BGTaskSchedulerPermittedIdentifiers` in
  /// `MiraApp/Supporting/Info.plist`, the plist both apps are built with.
  static let identifier = "com.codeaustral.mira.refresh"
  /// Ask for the next wake half an hour out. iOS adjusts this as it sees fit.
  static let earliestInterval: TimeInterval = 30 * 60
  /// A wake gets a few seconds, not the app's full patience.
  static let requestTimeout: TimeInterval = 6

  /// Call before the app finishes launching — each app entry point does, in
  /// its `init`. Registering later is a crash, and a missing plist key is one
  /// too.
  static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      handle(refresh)
    }
  }

  /// Ask iOS for the next wake. Called when the app goes to the background and
  /// again when a wake begins, so exactly one request is pending.
  static func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date().addingTimeInterval(earliestInterval)
    try? BGTaskScheduler.shared.submit(request)
  }

  private static func handle(_ task: BGAppRefreshTask) {
    schedule()
    let work = Task { @MainActor in
      let finished = await refreshOnce()
      task.setTaskCompleted(success: finished)
    }
    task.expirationHandler = { work.cancel() }
  }

  /// One wake: one GET, then a local comparison. Returns whether the wake used
  /// its time; the caller reports that to iOS.
  @MainActor
  static func refreshOnce() async -> Bool {
    let notices = ReminderNoticeStore()
    var payload = notices.load()
    let tasks = AgentTaskStore().load().tasks
    let activeThreadId = ChatThreadStore().load().activeThreadId
    let enabled = LocalDirectoryStore().renewalReminders
    guard let candidate = TaskNotice.candidate(tasks, activeThreadId: activeThreadId) else {
      return true
    }

    let brand = CurrentBrand.theme.kind
    let outcome = await MiraOrchestratorClient(timeout: requestTimeout).task(
      id: candidate.id, brand: brand)

    switch outcome {
    case .success(let fresh):
      // The first observation is a baseline, not news.
      guard let previous = payload.told[fresh.id] else {
        payload.told[fresh.id] = TaskNotice.fingerprint(fresh)
        notices.save(payload)
        return true
      }
      let changed = TaskNotice.changed([fresh], told: [fresh.id: previous])
      payload.told[fresh.id] = TaskNotice.fingerprint(fresh)
      notices.save(payload)
      guard enabled, let task = changed.first else { return true }
      await ReminderCenter.shared.post(
        TaskNotice.notice(for: task),
        canceling: task.watch != nil ? [Reminders.watchMissID(for: task.id)] : [])
      return true

    case .failure:
      // The proxy is unreachable at this moment. A watch whose check is due
      // says so, once per check window; nothing else is worth a notification.
      guard enabled, let watch = candidate.watch, watch.active,
        let next = Reminders.watchDate(watch.nextCheckAt), next <= Date()
      else { return true }
      guard payload.missed[candidate.id] != watch.nextCheckAt else { return true }
      guard let notice = Reminders.watchMissReminder(for: candidate, fireDate: Date()) else {
        return true
      }
      payload.missed[candidate.id] = watch.nextCheckAt
      notices.save(payload)
      await ReminderCenter.shared.post(
        notice, canceling: [Reminders.watchMissID(for: candidate.id)])
      return true
    }
  }
}
