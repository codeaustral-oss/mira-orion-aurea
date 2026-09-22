import Foundation

// MARK: - An agent task
//
// A research or comparison request does not finish inside one turn. The server
// accepts the work, returns an acknowledgement plus a task id, and the app polls
// until the task reaches a terminal state. This file is the app's copy of that
// task: what the wire carries, what the UI renders, and what is persisted so a
// relaunch can resume polling.
//
// Everything here is a display of server state. The app never invents a source,
// a price or a step: a task that has not completed shows exactly what the server
// last said, and a failure is shown as a failure.

struct AgentTask: Identifiable, Sendable, Equatable {
  enum Status: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case needsInput = "needs_input"

    /// No further polling is useful. `completed` and `failed` are finished;
    /// `needsInput` is a terminal waiting state — the server has nothing new to
    /// say until the next user message resumes the task on the same id.
    var isTerminal: Bool {
      self == .completed || self == .failed || self == .needsInput
    }

    var isActive: Bool { self == .queued || self == .running }

    var label: String {
      switch self {
      case .queued: return "Queued"
      case .running: return "Working"
      case .completed: return "Done"
      case .failed: return "Failed"
      case .needsInput: return "Needs your input"
      }
    }
  }

  struct Source: Codable, Sendable, Equatable, Identifiable {
    var title: String
    var url: String
    /// The page's own share image, when it declared one. Optional everywhere:
    /// a source without a picture is still a source.
    var thumbnail: String? = nil
    var id: String { "\(url)|\(title)" }
  }

  /// A standing watch: what it checks, what it last saw, and when it looks
  /// again. Present only on watch tasks; a check that failed is recorded as a
  /// failed check, never as a silent gap.
  struct Watch: Codable, Sendable, Equatable {
    var active: Bool
    var cadence: String
    var lastCheckAt: Double?
    var nextCheckAt: Double?
    var lastSummary: String
    var lastPrice: String?
    var lastOk: Bool
    var checkCount: Int

    var cadenceLabel: String {
      switch cadence {
      case "hourly": return "every hour"
      case "weekly": return "every week"
      case "monthly": return "every month"
      default: return "every day"
      }
    }
  }

  /// One thing Mira found, offered as a choice rather than a search result.
  struct Option: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var url: String?
    var why: String
    /// Only ever set when the page itself stated a price.
    var priceNote: String?
    /// The page's own share image, read by the server from its metadata. Absent
    /// is normal: the pick is still complete without a picture.
    var image: String?
    var id: String { "\(name)|\(url ?? "")" }
  }

  struct Artifact: Codable, Sendable, Equatable, Identifiable {
    var title: String
    var url: String
    var mimeType: String?
    var id: String { "\(url)|\(title)" }
  }

  struct Step: Codable, Sendable, Equatable, Identifiable {
    /// The server's own label. Never composed by the app.
    var label: String
    /// "queued", "running", "completed", "failed" — free-form on purpose, so an
    /// unknown value degrades to a neutral dot rather than a crash.
    var status: String
    var id: String { label }

    var isDone: Bool {
      let value = status.lowercased()
      return value == "completed" || value == "done" || value == "complete"
    }

    var isActive: Bool {
      let value = status.lowercased()
      return value == "running" || value == "active" || value == "in_progress"
    }

    var isFailed: Bool {
      let value = status.lowercased()
      return value == "failed" || value == "error"
    }
  }

  var id: String
  var brand: String
  var status: Status
  var title: String
  /// The answer, in Mira's own words: two or three sentences, written for a
  /// person deciding — not a report about how the research went.
  var summary: String
  /// The choices worth their time, best first.
  var options: [Option] = []
  /// One sentence on what to do next.
  var nextStep: String?
  /// One sentence, only when something genuinely could not be checked.
  var caveat: String?
  var question: String?
  var sources: [Source]
  var artifacts: [Artifact]
  var steps: [Step]
  var error: String?
  /// The capability that produced this task ("shopping", "watch", …), when the
  /// server says so. Optional: an older record simply has none.
  var kind: String? = nil
  /// Set only on watch tasks: the schedule and the last check.
  var watch: Watch? = nil
  /// The details the task was given — route, dates, party size, product. The
  /// card renders an itinerary or a reservation from these.
  var slots: [String: String] = [:]
  /// Which document the result is ("itinerary", "reservation", "picks",
  /// "watch"), decided when the run finished. Nil on older records: the card
  /// falls back to what the capability and the slots imply.
  var layout: String? = nil

  /// The conversation this task belongs to. Local only: the server scopes a task
  /// to brand + conversation, and the app uses this to keep a task's progress on
  /// the exact turn and thread that created it.
  var threadId: UUID?
  /// Local only: a transient transport problem while polling. Never a substitute
  /// for the server's own status or error.
  var pollError: String?
  /// Local only: the message that started this task — the ask, not a refinement.
  /// It is what a retry re-runs when the task service has no retry route of its
  /// own. The server never sends it; the app records it from the turn.
  var request: String? = nil
  /// Local only: the most recent user message that continued this task (an
  /// answer to its question, a refinement). A retry re-runs ask + refinement.
  var lastInput: String? = nil
  /// Local only: whether a full reading has ever replaced the acknowledgement
  /// that came back with the turn. The acknowledgement carries an id, a title
  /// and a status — never the question, summary, steps or sources — so an
  /// un-hydrated record still has to be fetched once, even when its
  /// acknowledged status already looks terminal.
  var isHydrated: Bool
  var createdAt: Date
  var updatedAt: Date

  init(
    id: String,
    brand: String,
    status: Status,
    title: String,
    summary: String = "",
    question: String? = nil,
    sources: [Source] = [],
    artifacts: [Artifact] = [],
    steps: [Step] = [],
    error: String? = nil,
    threadId: UUID? = nil,
    pollError: String? = nil,
    request: String? = nil,
    lastInput: String? = nil,
    isHydrated: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.brand = brand
    self.status = status
    self.title = title
    self.summary = summary
    self.question = question
    self.sources = sources
    self.artifacts = artifacts
    self.steps = steps
    self.error = error
    self.threadId = threadId
    self.pollError = pollError
    self.request = request
    self.lastInput = lastInput
    self.isHydrated = isHydrated
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// Merge a fresh wire reading over the local record, keeping the local
  /// association (thread, creation time) and clearing a transport error.
  func applying(_ wire: AgentTask) -> AgentTask {
    var merged = wire
    merged.threadId = threadId ?? wire.threadId
    merged.createdAt = createdAt
    merged.pollError = nil
    // The request bookkeeping is the app's own: the wire never carries it, so a
    // fresh reading must not wipe what a retry depends on.
    merged.request = request ?? wire.request
    merged.lastInput = lastInput ?? wire.lastInput
    // A real reading is the hydration: the acknowledgement's placeholders are
    // gone, including an old question or an old set of results from an earlier
    // run that reused this id.
    merged.isHydrated = true
    merged.updatedAt = Date()
    return merged
  }

  /// An acknowledgement is not the task. Until a real reading has landed, the
  /// record still has to be fetched once.
  var needsHydration: Bool { !isHydrated }

  /// A failed poll is not a failed task. Keep the last known status and record
  /// only the transport problem.
  func tracking(_ message: String) -> AgentTask {
    var updated = self
    updated.pollError = message
    updated.updatedAt = Date()
    return updated
  }

  var displayTitle: String {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? "Research task" : clean
  }
}

// MARK: - Lenient decoding
//
// The server contract says every collection defaults to empty and optional
// fields may be null. This decoder holds to that: a missing key, a null or an
// unknown status never fails a whole task, and never loses the rest of it.

extension AgentTask: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, brand, status, title, summary, question
    case options, nextStep, caveat
    case sources, artifacts, steps, error, kind, watch, slots, layout
    case threadId, pollError, request, lastInput, isHydrated, createdAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(String.self, forKey: .id)) ?? ""
    brand = (try? c.decode(String.self, forKey: .brand)) ?? ""
    let raw = (try? c.decode(String.self, forKey: .status)) ?? Status.queued.rawValue
    status = Status(rawValue: raw) ?? .queued
    title = (try? c.decode(String.self, forKey: .title)) ?? ""
    summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
    question = ((try? c.decodeIfPresent(String.self, forKey: .question)) ?? nil)
    // The answer's choices, its next step and its caveat. Written by hand here
    // like every other field: a synthesised decoder would have quietly dropped
    // them, which is exactly what happened to the picks.
    options = ((try? c.decodeIfPresent([Option].self, forKey: .options)) ?? nil) ?? []
    nextStep = ((try? c.decodeIfPresent(String.self, forKey: .nextStep)) ?? nil)
    caveat = ((try? c.decodeIfPresent(String.self, forKey: .caveat)) ?? nil)
    sources = ((try? c.decodeIfPresent([Source].self, forKey: .sources)) ?? nil) ?? []
    artifacts = ((try? c.decodeIfPresent([Artifact].self, forKey: .artifacts)) ?? nil) ?? []
    steps = ((try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? nil) ?? []
    error = ((try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil)
    kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil)
    watch = ((try? c.decodeIfPresent(Watch.self, forKey: .watch)) ?? nil)
    // Slots carry nulls for details the task never got ("time": null). Decoded
    // as optional values, then compacted — a decoder that demanded strings
    // silently dropped the whole map, and with it the itinerary and the
    // reservation documents that are built from it.
    if let raw = try? c.decodeIfPresent([String: String?].self, forKey: .slots) {
      slots = (raw ?? [:]).compactMapValues { $0 }
    } else {
      slots = [:]
    }
    layout = ((try? c.decodeIfPresent(String.self, forKey: .layout)) ?? nil)
    threadId = ((try? c.decodeIfPresent(UUID.self, forKey: .threadId)) ?? nil)
    pollError = ((try? c.decodeIfPresent(String.self, forKey: .pollError)) ?? nil)
    request = ((try? c.decodeIfPresent(String.self, forKey: .request)) ?? nil)
    lastInput = ((try? c.decodeIfPresent(String.self, forKey: .lastInput)) ?? nil)
    // An older saved record never hydrated under this rule, so it defaults to
    // un-hydrated and gets one fetch.
    isHydrated = (try? c.decode(Bool.self, forKey: .isHydrated)) ?? false
    createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(brand, forKey: .brand)
    try c.encode(status.rawValue, forKey: .status)
    try c.encode(title, forKey: .title)
    try c.encode(summary, forKey: .summary)
    try c.encodeIfPresent(question, forKey: .question)
    if !options.isEmpty { try c.encode(options, forKey: .options) }
    try c.encodeIfPresent(nextStep, forKey: .nextStep)
    try c.encodeIfPresent(caveat, forKey: .caveat)
    if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
    if !artifacts.isEmpty { try c.encode(artifacts, forKey: .artifacts) }
    if !steps.isEmpty { try c.encode(steps, forKey: .steps) }
    try c.encodeIfPresent(error, forKey: .error)
    try c.encodeIfPresent(kind, forKey: .kind)
    try c.encodeIfPresent(watch, forKey: .watch)
    if !slots.isEmpty { try c.encode(slots, forKey: .slots) }
    try c.encodeIfPresent(layout, forKey: .layout)
    try c.encodeIfPresent(threadId, forKey: .threadId)
    try c.encodeIfPresent(pollError, forKey: .pollError)
    try c.encodeIfPresent(request, forKey: .request)
    try c.encodeIfPresent(lastInput, forKey: .lastInput)
    try c.encode(isHydrated, forKey: .isHydrated)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(updatedAt, forKey: .updatedAt)
  }
}

// MARK: - Scope
//
// A task is shown only on the conversation that created it. This is the whole
// thread-isolation rule, in one place so it can be tested directly.

enum AgentTaskScope {
  static func isVisible(_ task: AgentTask, in threadId: UUID?) -> Bool {
    guard let threadId else { return false }
    return task.threadId == threadId
  }
}

// MARK: - Retry
//
// A failed task's only way out is a retry that actually goes back to the task
// service. Two pure decisions live here: whether a task is worth retrying, and
// what message a re-run should carry.

/// What a retry re-sends, and for which task.
struct TaskRetryPlan: Equatable, Sendable {
  var taskId: String
  var message: String
}

enum TaskRetry {
  /// A failure is retryable. So is a task whose polling gave up on a transport
  /// error — the work may still be there, it was only the reading that failed.
  /// A completed task is not, and a question waiting on the person is answered,
  /// not retried.
  static func isWorthRetrying(_ task: AgentTask) -> Bool {
    task.status == .failed || task.pollError != nil
  }

  /// The request a retry re-runs: the ask that created the task plus the last
  /// refinement the person gave it. When the app recorded neither (an older
  /// record), fall back to the nearest user turn before the task's own card.
  static func plan(
    for task: AgentTask, in turns: [ConversationTurn], threadId: UUID?
  ) -> TaskRetryPlan? {
    guard isWorthRetrying(task) else { return nil }
    // The task must belong to the conversation it is being retried from: a card
    // from another thread is not on screen, so its chip cannot be pressed.
    guard task.threadId == threadId else { return nil }

    let ask = task.request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let last = task.lastInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !ask.isEmpty {
      let message = last.isEmpty || last == ask ? ask : "\(ask) \(last)"
      return TaskRetryPlan(taskId: task.id, message: message)
    }

    guard
      let index = turns.lastIndex(where: {
        $0.action?.kind == .agentTask && $0.action?.taskId == task.id
      })
    else { return nil }
    for turn in turns[..<index].reversed() where turn.role == .user {
      let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return TaskRetryPlan(taskId: task.id, message: text) }
    }
    return nil
  }
}


// MARK: - Polling backoff
//
// A pure function so the schedule is testable without a clock. Slow enough to be
// polite, fast enough that a short task feels live.

/// How often to ask.
///
/// A task is a minute of work, and the card carries a live line while it runs:
/// polling every few seconds is what makes that line live rather than stale. The
/// backoff still exists, but it is gentle — this is one small GET, and the
/// alternative is a card that appears frozen.
enum TaskPollBackoff {
  static let initial: TimeInterval = 1.5
  static let maximum: TimeInterval = 6.0

  static func delay(attempt: Int) -> TimeInterval {
    let step = Double(max(0, attempt))
    let value = initial * pow(1.25, step)
    return min(maximum, value)
  }
}

// MARK: - Poll policy
//
// When a task is worth (re)starting a poller for. An acknowledged task is always
// fetched once, even if the acknowledgement already looks terminal, because the
// acknowledgement never carries the question, summary, steps or sources. After
// that first reading only a non-terminal task keeps polling.

enum AgentTaskPollPolicy {
  static func shouldPoll(_ task: AgentTask) -> Bool {
    task.needsHydration || !task.status.isTerminal
  }
}

// MARK: - Persistence
//
// Task ids, their thread association and their last known state survive a
// relaunch, so polling resumes where it left off. Atomically written, like the
// conversation store.

struct AgentTaskPayload: Codable, Sendable {
  var version: Int = 1
  var tasks: [AgentTask] = []
}

final class AgentTaskStore {
  private let path: URL

  init(path: URL? = nil) {
    self.path = path ?? AgentTaskStore.defaultPath()
  }

  static func defaultPath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Mira", isDirectory: true)
      .appendingPathComponent("tasks.json")
  }

  func load() -> AgentTaskPayload {
    do {
      let data = try Data(contentsOf: path)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let payload = try decoder.decode(AgentTaskPayload.self, from: data)
      return AgentTaskPayload(version: payload.version, tasks: payload.tasks)
    } catch {
      // A missing file is the normal first-run case, not an error.
      return AgentTaskPayload(version: 1, tasks: [])
    }
  }

  func save(_ payload: AgentTaskPayload) {
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
      // Losing a task write never blocks the conversation; the in-memory record
      // is still usable for this session and polling continues.
    }
  }
}
