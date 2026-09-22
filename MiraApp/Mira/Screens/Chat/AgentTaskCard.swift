import SwiftUI

// MARK: - Agent task card
//
// One card for the whole life of a research task: queued, working, needs your
// input, done, or failed. It is deliberately compact — a title, a state, the
// server's own steps, and then only the parts that exist. Every source and
// artifact is a real link from the server, rendered as a link or, when the URL
// is not a usable web address, as plain text rather than a dead control.
//
// Nothing here is invented: an unfinished task shows the steps it has, and a
// failure is shown as a failure with an honest retry.

struct AgentTaskCard: View {
  let action: AgentAction

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  private var task: AgentTask? { session.task(for: action) }

  private var status: AgentTask.Status {
    task?.status ?? action.taskStatus.flatMap(AgentTask.Status.init(rawValue:)) ?? .queued
  }

  private var title: String {
    if let task, !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return task.title
    }
    if let title = action.taskTitle, !title.isEmpty { return title }
    return "Mira is on it"
  }

  /// The question this card is asking, when it is asking one.
  private var question: String? {
    Self.askedQuestion(status: status, question: task?.question)
  }

  /// What a question is about: the task's own title. Never the header's
  /// fallback ("Mira is on it") — that is a status, not a subject.
  private var subject: String? {
    if let task { return Self.questionSubject(task.title) }
    return Self.questionSubject(action.taskTitle)
  }

  var body: some View {
    if status == .queued || status == .running {
      workingCard
    } else {
      ChatCard(footer: footer) {
        // A `needs_input` question is the card's own message: the subject, the
        // question at reading size, and the controls that answer it. Every other
        // state keeps the standard header.
        if let question = question {
          questionCard(question)
        } else {
          header

          stateBody

          if let id = action.taskId, !id.isEmpty {
            controls(taskId: id)
          }
        }
      }
    }
  }

  private var workingCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ProgressView().tint(brand.accentDeep)
        Text(status == .queued ? "Getting started" : "Working on your request")
          .font(MiraFont.label(15))
        Spacer(minLength: 4)
        if let id = action.taskId {
          Button { Task { await session.cancelTask(id) } } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Cancel request")
        }
      }
      Text(task.map(progressLine) ?? "Waiting for the first update…")
        .font(MiraFont.body(14)).foregroundStyle(brand.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if let error = task?.pollError {
        Text(error).font(MiraFont.caption(12)).foregroundStyle(brand.textSecondary)
        if let id = action.taskId {
          Button("Reconnect") { Task { await session.retryTask(id) } }
            .font(MiraFont.label(14))
        }
      }
    }
    .padding(16)
    .background(brand.hairline.opacity(0.25), in: RoundedRectangle(cornerRadius: 20))
  }

  /// Everything a card shows once its state is not a question.
  @ViewBuilder
  private var stateBody: some View {
    if let task {
      if status.isActive {
        // A person waiting wants to know that something is happening, not
        // which internal step is running. One line, and the dot that never
        // stops moving while Mira is actually working.
        HStack(spacing: Space.xs) {
          MiraDot(size: 8, pulsing: true)
          Text(progressLine(task))
            .font(MiraFont.body(14))
            .foregroundStyle(brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Space.xxs)
      }

      if status == .completed {
        completed(task)
      }

      if let watch = task.watch, status == .completed || status == .failed {
        watchBlock(watch)
      }

      if status == .failed {
        failed(task)
      }

      if status.isActive, let pollError = task.pollError {
        Text(pollError)
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      // The acknowledgement arrived but the task record has not yet been
      // restored or polled. Say that plainly rather than inventing progress.
      Text("Task \(action.taskId ?? "—") acknowledged. Waiting for the first update.")
        .font(MiraFont.body(14))
        .foregroundStyle(brand.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .top, spacing: Space.sm) {
      statusMark
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(MiraFont.title(16))
          .foregroundStyle(brand.text)
          .fixedSize(horizontal: false, vertical: true)
        if !headline.isEmpty {
          Text(headline)
            .font(MiraFont.body(14))
            .foregroundStyle(brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: Space.xs)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title). \(status.label). \(headline)")
  }

  private var headline: String {
    switch status {
    // While a task runs, the line under the title does the talking (see
    // `progressLine`); the title does not repeat it.
    case .queued: return ""
    case .running: return ""
    // The summary below is the answer; a headline over it is one more line to
    // read for nothing.
    case .completed: return ""
    case .failed: return "That did not finish."
    case .needsInput: return ""
    }
  }

  private var statusMark: some View {
    ZStack {
      Circle().fill(tone.color.opacity(0.12)).frame(width: 30, height: 30)
      if status == .running || status == .queued {
        MiraDot(size: 9, pulsing: true)
      } else {
        Image(systemName: tone.glyph)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(tone.color)
      }
    }
    .accessibilityHidden(true)
  }

  private var tone: StatusTone {
    switch status {
    case .queued: return .neutral
    case .running: return .progress
    case .completed: return .positive
    case .failed: return .negative
    case .needsInput: return .progress
    }
  }

  // MARK: Completed

  @ViewBuilder
  private func completed(_ task: AgentTask) -> some View {
    let parts = Self.summaryParts(task.summary)

    // A trip or a table is a document before it is a list of links: lead with
    // the itinerary or the reservation, then the picks that make it happen.
    if let document = Self.document(for: task) {
      ReceiptCardView(receipt: document, compact: true)
      Rule()
    }

    // The lead is the answer, so it reads at title scale; the rest is the
    // explanation and follows one size down and secondary. Both registers are
    // on the card, so there is no "More detail" left to open onto the same
    // sentences.
    if !parts.lead.isEmpty || parts.rest != nil {
      VStack(alignment: .leading, spacing: Space.xxs) {
        if !parts.lead.isEmpty {
          Text(parts.lead)
            .font(MiraFont.title(18))
            .foregroundStyle(brand.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let rest = parts.rest {
          Text(rest)
            .font(MiraFont.body(15))
            .foregroundStyle(brand.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    if !task.options.isEmpty {
      Rule()
      optionsSection(task.options)
    }

    if let next = task.nextStep, !next.isEmpty {
      Rule()
      HStack(alignment: .top, spacing: Space.xs) {
        Image(systemName: "arrow.turn.down.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(brand.accentDeep)
          .padding(.top, 2)
        Text(next)
          .font(MiraFont.body(14))
          .foregroundStyle(brand.text)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    if let caveat = task.caveat, !caveat.isEmpty {
      Text(caveat)
        .font(MiraFont.caption(12))
        .foregroundStyle(brand.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    if !task.sources.isEmpty {
      Rule()
      sourcesSection(task.sources)
    }
  }

  /// A standing watch: what it last saw and when it looks again, with the two
  /// honest controls a standing check needs — run one now, or stop it.
  @ViewBuilder
  private func watchBlock(_ watch: AgentTask.Watch) -> some View {
    Rule()
    VStack(alignment: .leading, spacing: Space.xxs) {
      HStack(spacing: Space.xxs) {
        Image(systemName: watch.active ? "eye" : "eye.slash")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(watch.active ? brand.accentDeep : brand.textTertiary)
        Text(watch.active ? "Watching \(watch.cadenceLabel)" : "Watch stopped")
          .font(MiraFont.label(13))
          .foregroundStyle(brand.text)
        Spacer(minLength: 0)
        if watch.active, let next = watch.nextCheckAt {
          Text("Next \(Self.relativeTime(next))")
            .font(MiraFont.caption(12))
            .foregroundStyle(brand.textTertiary)
        }
      }
      if !watch.lastSummary.isEmpty {
        Text(watch.lastSummary)
          .font(MiraFont.body(14))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if watch.active, let id = action.taskId, !id.isEmpty {
        HStack(spacing: Space.xs) {
          Button("Check now") { Task { await session.checkWatchNow(id) } }
            .buttonStyle(TaskQuietButtonStyle())
          Button("Stop") { Task { await session.stopWatch(id) } }
            .buttonStyle(TaskQuietButtonStyle())
          Spacer(minLength: 0)
        }
        .padding(.top, Space.xxs)
      }
    }
  }

  /// "in 6 h" / "in 20 min" — the schedule is a horizon, not a date.
  static func relativeTime(_ timestamp: Double) -> String {
    let seconds = Int(timestamp / 1000 - Date().timeIntervalSince1970)
    if seconds <= 0 { return "now" }
    if seconds < 3600 { return "in \((seconds + 59) / 60) min" }
    if seconds < 86_400 { return "in \((seconds + 3599) / 3600) h" }
    return "in \((seconds + 86_399) / 86_400) days"
  }

  /// The choices Mira found, best first. The first is the recommendation and
  /// reads a notch stronger than the alternatives; every row is a line a person
  /// can act on: what it is, why it is worth their time, and what it costs if
  /// the page said.
  private func optionsSection(_ options: [AgentTask.Option]) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionLabel("Mira's picks", count: options.count)
      VStack(spacing: 0) {
        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
          if index > 0 { Rule() }
          optionRow(option, isLead: index == 0)
        }
      }
    }
  }

  @ViewBuilder
  private func optionRow(_ option: AgentTask.Option, isLead: Bool) -> some View {
    if let raw = option.url, let destination = Self.webURL(raw) {
      Link(destination: destination) { optionBody(option, opens: true, isLead: isLead) }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(option.name)")
    } else {
      optionBody(option, opens: false, isLead: isLead)
    }
  }

  private func optionBody(_ option: AgentTask.Option, opens: Bool, isLead: Bool) -> some View {
    HStack(alignment: .top, spacing: Space.sm) {
      if let thumbnail = Self.thumbnailURL(option.image) {
        AsyncImage(url: thumbnail) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          default:
            // A quiet block while it loads, or when the picture never arrives.
            Rectangle().fill(brand.surface)
          }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(option.name)
          .font(isLead ? MiraFont.label(16) : MiraFont.label(15))
          .foregroundStyle(brand.text)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        if !option.why.isEmpty {
          Text(option.why)
            .font(MiraFont.body(13.5))
            .foregroundStyle(brand.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: Space.xs)
      VStack(alignment: .trailing, spacing: 4) {
        if let price = option.priceNote, !price.isEmpty {
          Text(price)
            .font(isLead ? MiraFont.figure(15, weight: .semibold) : MiraFont.figure(13.5))
            .foregroundStyle(brand.text)
            .lineLimit(1)
        }
        if opens {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(brand.textTertiary)
        }
      }
      .padding(.top, 2)
    }
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }

  /// One calm line while a task runs, and the live one when the server has it.
  ///
  /// The runtime reports what the agent is actually doing — which query it is
  /// on, how many pages it is reading — so the line changes while the work
  /// happens instead of sitting still for a minute. A reading that says nothing
  /// concrete keeps the last distinct line the session remembered: the same
  /// words are never re-rendered as if they were new work.
  private func progressLine(_ task: AgentTask) -> String {
    let live = task.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !live.isEmpty, live != MiraSession.placeholderProgress { return live }
    // The server has said nothing concrete this time. The line already on
    // screen is more honest than the calm default, and saying it again is not
    // new work — so it stays until a genuinely different reading arrives.
    if let remembered = session.taskProgressLines[task.id], !remembered.isEmpty {
      return remembered
    }
    switch status {
    case .queued:
      return "Mira is on it."
    default:
      return "Checking sources. The answer will appear here."
    }
  }

  /// A long answer reads as a wall. The first sentence or two is the answer; the
  /// rest is the working, and it belongs behind one tap.
  static func summaryParts(_ text: String) -> (lead: String, rest: String?) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.count > 200 else { return (clean, nil) }
    let limit = clean.index(clean.startIndex, offsetBy: 200)
    let head = clean[clean.startIndex..<limit]
    guard let cut = head.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else {
      return (clean, nil)
    }
    let lead = String(clean[clean.startIndex...cut])
    let rest = String(clean[clean.index(after: cut)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (lead, rest.isEmpty ? nil : rest)
  }

  // MARK: Needs input

  /// The question card: what is being asked about, the question itself at
  /// reading size, and the controls that move it on. No footer — the question
  /// is the message.
  private func questionCard(_ question: String) -> some View {
    let subject = self.subject
    return VStack(alignment: .leading, spacing: Space.sm) {
      // The subject and the question read as one announcement; the controls
      // below stay their own elements.
      VStack(alignment: .leading, spacing: Space.xxs) {
        if let subject {
          Text(subject)
            .font(MiraFont.label(13))
            .foregroundStyle(brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(question)
          .font(MiraFont.body(20))
          .foregroundStyle(brand.text)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        [subject, AgentTask.Status.needsInput.label, question].compactMap { $0 }
          .joined(separator: ". ")
      )

      // The way to answer is right here: the chips under the card, and the one
      // control the task itself offers.
      if let id = action.taskId, !id.isEmpty {
        controls(taskId: id)
      }
    }
  }

  /// The question a card is asking, or nil. Only a `needs_input` task with a
  /// real question is asking something; whitespace is not a question.
  static func askedQuestion(status: AgentTask.Status, question: String?) -> String? {
    guard status == .needsInput else { return nil }
    let clean = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
  }

  /// The small line above a question: what it is about, from the task's own
  /// title. Nil when there is no title — a question needs no heading to be
  /// clear, and a placeholder is not a subject.
  static func questionSubject(_ raw: String?) -> String? {
    let clean = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
  }

  /// Whether a turn's own line is the question its task card is asking. The
  /// card owns the question then, and the turn must not print it above the card
  /// as well.
  static func carriesQuestion(_ task: AgentTask?, spoken: String) -> Bool {
    guard let task,
      let question = askedQuestion(status: task.status, question: task.question)
    else { return false }
    return sameLine(question, spoken)
  }

  // MARK: Failed

  private func failed(_ task: AgentTask) -> some View {
    // The failure states what happened. The way out of it is the single control
    // in the row below this — drawn twice, it looked like two different actions.
    VStack(alignment: .leading, spacing: Space.sm) {
      Rule()
      Text(Self.humanFailure(task.error))
        .font(MiraFont.body(14))
        .foregroundStyle(brand.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Links

  /// Where the answer came from: the site's own icon, the page, and where it
  /// lives. A favicon is fetched from the site itself — nothing is sent to a
  /// third party to decorate a link.
  private func sourcesSection(_ sources: [AgentTask.Source]) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      sectionLabel("Where this came from", count: sources.count)
      VStack(spacing: 0) {
        ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
          if index > 0 {
            Rule().padding(.leading, 38)
          }
          linkRow(
            title: source.title, url: source.url, mime: nil, isArtifact: false,
            thumbnail: source.thumbnail)
        }
      }
    }
  }

  private func sectionLabel(_ text: String, count: Int) -> some View {
    HStack(spacing: 5) {
      Text(text.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(brand.textTertiary)
      if count > 1 {
        Text("\(count)")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(brand.textTertiary.opacity(0.75))
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func linkRow(
    title: String, url: String, mime: String?, isArtifact: Bool, thumbnail: String?
  ) -> some View {
    if let destination = isArtifact
      ? Self.artifactURL(url, baseURL: JevProxyClient.defaultBaseURL, brand: session.brandKind)
      : Self.webURL(url)
    {
      Link(destination: destination) {
        HStack(alignment: .center, spacing: Space.sm) {
          if isArtifact {
            artifactMark
          } else {
            SourceMark(host: destination.host, thumbnail: thumbnail)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text(title.isEmpty ? destination.host ?? url : title)
              .font(MiraFont.body(14))
              .foregroundStyle(brand.text)
              .multilineTextAlignment(.leading)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
            Text(detailLine(for: destination, mime: mime, isArtifact: isArtifact))
              .font(MiraFont.caption(11))
              .foregroundStyle(brand.textTertiary)
              .lineLimit(1)
          }
          Spacer(minLength: Space.xs)
          Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(brand.textTertiary)
        }
        .padding(.vertical, 7)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open \(title.isEmpty ? (destination.host ?? url) : title)")
    } else {
      HStack(alignment: .top, spacing: Space.xs) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 12))
          .foregroundStyle(MiraColor.failed)
          .padding(.top, 2)
        Text(title.isEmpty ? url : "\(title) — \(url)")
          .font(MiraFont.body(13))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// A document mark for a prepared file: the local report, not a web page.
  private var artifactMark: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(brand.accentTint)
      Image(systemName: "doc.text")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(brand.accentDeep)
    }
    .frame(width: 26, height: 26)
    .accessibilityHidden(true)
  }

  private func detailLine(for destination: URL, mime: String?, isArtifact: Bool) -> String {
    if isArtifact {
      let kind = (mime ?? "").contains("markdown") ? "Markdown" : "File"
      return "\(kind) · prepared by Mira"
    }
    return destination.host ?? destination.absoluteString
  }

  /// Only http(s) addresses become links.
  static func webURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }

  /// Thumbnails load over https only: the server upgrades what it can, and a
  /// frame that cannot load is not worth occupying.
  /// The document a task's own details amount to, when it amounts to one.
  ///
  /// The layout is decided server-side when the run finishes — a typed read of
  /// what the result *is*, with the shape of the result as the fallback. Older
  /// records have no layout, so the capability and the slots stand in for it.
  static func document(for task: AgentTask) -> ReceiptSpec? {
    let layout = task.layout ?? impliedLayout(for: task)
    switch layout {
    case "itinerary": return ReceiptSpec.itinerary(task: task)
    case "reservation": return ReceiptSpec.reservation(task: task)
    case "order": return ReceiptSpec.order(task: task)
    default: return nil
    }
  }

  /// What the capability and the slots imply, for a record with no layout.
  static func impliedLayout(for task: AgentTask) -> String {
    switch task.kind {
    case "travel": return "itinerary"
    case "restaurant": return task.slots["mode"] == "delivery" ? "picks" : "reservation"
    case "watch": return "watch"
    default: return "picks"
    }
  }

  static func thumbnailURL(_ raw: String?) -> URL? {
    guard let raw, let url = webURL(raw), url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  /// Local reports use the same server and brand scope as task polling.
  /// A relative source URL must never be interpreted as a local report.
  static func artifactURL(_ raw: String, baseURL: URL, brand: BrandKind) -> URL? {
    let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let external = webURL(clean) { return external }
    guard clean.hasPrefix("/v1/artifacts/"),
      let input = URLComponents(string: clean),
      input.scheme == nil, input.host == nil,
      input.query == nil, input.fragment == nil,
      !input.path.contains(".."),
      input.path.range(
        of: "^/v1/artifacts/task_[A-Za-z0-9]+/[A-Za-z0-9][A-Za-z0-9._-]*$",
        options: .regularExpression) != nil,
      var destination = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    destination.path = input.path
    destination.queryItems = [URLQueryItem(name: "brand", value: brand.rawValue)]
    destination.fragment = nil
    return destination.url.flatMap { webURL($0.absoluteString) }
  }

  // MARK: Controls

  /// The server's failure line, said the way Mira would say it. An unfamiliar
  /// message is passed through rather than replaced with a guess.
  static func humanFailure(_ raw: String?) -> String {
    let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "That did not finish." }
    if text.hasPrefix("Hermes wrapper") || text.hasPrefix("The task agent exited")
      || text.contains("in the server environment") {
      return "Research is temporarily unavailable. Please try again in a moment."
    }
    let known: [String: String] = [
      "The task agent returned no structured result.":
        "Mira could not put an answer together this time.",
      "The task agent used its turn budget without producing a result.":
        "Mira ran out of road before it found an answer.",
      "The task exceeded its time budget before finishing.":
        "This took longer than Mira allows, so it stopped.",
      "The task was cancelled.": "Stopped at your request.",
      "Cancelled by user.": "Stopped at your request.",
    ]
    return known[text] ?? text
  }

  /// Two lines are the same if they only differ in spacing or punctuation runs.
  /// Used to keep a `needs_input` question from being said twice: the card owns
  /// the question, and the turn's own line is dropped when it is that question.
  static func sameLine(_ a: String, _ b: String?) -> Bool {
    guard let b else { return false }
    func clean(_ text: String) -> String {
      text.lowercased()
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?")))
    }
    let left = clean(a)
    return !left.isEmpty && left == clean(b)
  }

  @ViewBuilder
  private func controls(taskId: String) -> some View {
    let canCancel = status.isActive || status == .needsInput
    // "Try again" exists only when a retry is real: a task that failed, or one
    // whose polling stopped on a transport error. Nothing else has a re-run.
    let canRetry = task.map(TaskRetry.isWorthRetrying) ?? false
    if canCancel || canRetry {
      VStack(alignment: .leading, spacing: Space.xs) {
        Rule()
        HStack(spacing: Space.xs) {
          if canRetry {
            Button("Try again") { Task { await session.retryTask(taskId) } }
              .buttonStyle(BrandButtonStyle(kind: .secondary, fullWidth: false))
          }
          if canCancel {
            Button("Cancel") { Task { await session.cancelTask(taskId) } }
              .buttonStyle(TaskQuietButtonStyle())
          }
          Spacer(minLength: 0)
        }
      }
      .padding(.top, Space.xxs)
    }
  }

  private var footer: String? {
    // A watch is not a one-off result: say what continues, not what was prepared.
    if let watch = task?.watch {
      if status == .failed { return "That check did not finish. Mira tries again on schedule." }
      if !watch.active { return "The watch is stopped; the last check stays here." }
      if status == .completed { return "Mira keeps checking on schedule. Nothing moves on its own." }
      return nil
    }
    switch status {
    case .failed:
      return "Mira can take another run at it."
    case .completed:
      return "Mira prepared this. You decide what happens next."
    case .needsInput:
      // The question is the message. A footer under it would instruct what the
      // chips and the one control already make plain.
      return question == nil ? "Answer below and I'll continue." : nil
    case .queued, .running:
      // The progress row above already says the work is happening. A footer
      // repeating it was two quiet lines for one fact, which reads as stutter.
      return nil
    }
  }
}

// MARK: - A source's mark

/// How a source is drawn: the page's own picture when it published one, and a
/// quiet monogram of its name when it did not.
///
/// Deliberately *not* a favicon. Half the web serves its platform's logo as its
/// icon, so a list decorated with favicons reads as a list of WordPress sites.
/// A monogram is always the site, never the CMS, and it costs no network call.
struct SourceMark: View {
  let host: String?
  let thumbnail: String?

  @Environment(\.brand) private var brand

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(brand.accentTint)

      if let url = imageURL {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          default:
            monogram
          }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      } else {
        monogram
      }
    }
    .frame(width: 26, height: 26)
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(brand.hairline, lineWidth: 1)
    }
    .accessibilityHidden(true)
  }

  /// The first letter of the site's name, as the site would write it: the host
  /// without its `www.` and without its suffix.
  private var monogram: some View {
    Text(initial)
      .font(.system(size: 12, weight: .semibold, design: .serif))
      .foregroundStyle(brand.accentDeep)
  }

  private var initial: String {
    var name = (host ?? "").lowercased()
    if name.hasPrefix("www.") { name.removeFirst(4) }
    guard let first = name.first, first.isLetter else { return "•" }
    return String(first).uppercased()
  }

  private var imageURL: URL? {
    guard let thumbnail, let url = URL(string: thumbnail),
      let scheme = url.scheme?.lowercased(), scheme == "https", url.host != nil
    else { return nil }
    return url
  }
}

/// A compact, quiet control for the two things you can do to a running task.
struct TaskQuietButtonStyle: ButtonStyle {
  @Environment(\.brand) private var brand

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(MiraFont.label(14))
      .foregroundStyle(brand.textSecondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .overlay { Capsule().strokeBorder(brand.hairline, lineWidth: 1) }
      .opacity(configuration.isPressed ? 0.7 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}
