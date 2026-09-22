import Foundation

// MARK: - Reply

/// One answer from a specialist.
///
/// The specialist writes prose only. It cannot move money, choose an amount or
/// approve anything, so there is no typed proposal here: the typed action
/// travels on the orchestration result instead, decided by deterministic code.
///
/// `citations`, `flags` and `proposal` remain part of the contract for the older
/// single-assistant surfaces. The orchestration path leaves them empty and
/// carries structure on the routed action instead.
struct AgentReply: Sendable {
  struct Flag: Identifiable, Sendable {
    enum Severity: String, Sendable { case info, warn }
    let id = UUID()
    let severity: Severity
    let text: String
  }

  struct Proposal: Sendable {
    enum Kind: String, Sendable { case swap, transfer, budget }
    let kind: Kind
    let title: String
    let detail: String
    let params: [String: String]
  }

  let say: String
  let citations: [String]
  let flags: [Flag]
  let proposal: Proposal?
  let structured: Bool
  let model: String
  let latencyMs: Int
  let agentSessionId: String?
  let specialistName: String?

  init(
    say: String,
    citations: [String] = [],
    flags: [Flag] = [],
    proposal: Proposal? = nil,
    structured: Bool = false,
    model: String,
    latencyMs: Int,
    agentSessionId: String? = nil,
    specialistName: String? = nil
  ) {
    self.say = say
    self.citations = citations
    self.flags = flags
    self.proposal = proposal
    self.structured = structured
    self.model = model
    self.latencyMs = latencyMs
    self.agentSessionId = agentSessionId
    self.specialistName = specialistName
  }

  var isEmpty: Bool { say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Orchestration client

/// Talks to the local proxy's orchestration route.
///
/// One call does the whole turn: Jev labels the intent, deterministic code
/// chooses the typed action and the specialist, and the model writes the prose.
/// A model failure is reported as a failure and never as an invented answer.
struct MiraOrchestratorClient: Sendable {
  var baseURL: URL
  var timeout: TimeInterval
  /// The transport. Injectable so the retry path can be proven against a stub
  /// instead of only by reading the code.
  var session: URLSession

  init(
    baseURL: URL = JevProxyClient.defaultBaseURL,
    timeout: TimeInterval = 150,
    // The session carries the proxy key when the installed bundle has one.
    session: URLSession = .miraProxy
  ) {
    self.baseURL = baseURL
    self.timeout = timeout
    self.session = session
  }

  func orchestrate(
    message: String,
    digest: String,
    brand: BrandKind,
    sessionId: String,
    conversationId: String,
    pending: PendingTransferContext?,
    history: [WireTurn],
    place: String? = nil
  ) async -> Result<OrchestrationResult, AgentError> {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/orchestrate"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // A high-effort model can genuinely take a while. The UI shows a working
    // state for the whole time rather than pretending to be instant.
    request.timeoutInterval = timeout
    request.httpBody = try? JSONEncoder().encode(
      Request(
        message: message, digest: digest, brand: brand.rawValue, sessionId: sessionId,
        conversationId: conversationId, pending: pending, history: history,
        place: place))

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(.unavailable("The proxy gave no answer."))
      }
      guard (200..<300).contains(http.statusCode) else {
        return .failure(.unavailable("The proxy answered \(http.statusCode)."))
      }
      let payload = try JSONDecoder().decode(Response.self, from: data)
      guard payload.ok else {
        return .failure(.unavailable(payload.detail ?? "The proxy could not route this message."))
      }
      return .success(payload.toResult(brand: brand))
    } catch is DecodingError {
      return .failure(.unavailable("The proxy answered in a shape this build does not understand."))
    } catch {
      return .failure(
        .unavailable("The proxy is not reachable at \(baseURL.absoluteString)."))
    }
  }

  // MARK: Tasks

  /// Read the current state of an agent task.
  func task(id: String, brand: BrandKind) async -> Result<AgentTask, TaskFetchError> {
    await taskRequest(id: id, brand: brand, method: "GET")
  }

  /// Ask the proxy's typed read: does this message authorise an action, supply
  /// a detail, and how much is at stake? A failed call is simply not a reading.
  func consentRead(message: String, action: String, known: [String: String]) async -> ConsentRead {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/consent"))
    request.httpMethod = "POST"
    request.timeoutInterval = 6
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["message": message, "action": action, "known": known])
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return ConsentRead(ok: false) }
      let decision = root["decision"] as? [String: Any]
      return ConsentRead(
        ok: root["ok"] as? Bool ?? false,
        authorises: root["authorises"] as? Double,
        suppliesDetail: root["suppliesDetail"] as? Double,
        missing: root["missing"] as? String,
        risk: root["risk"] as? String,
        decision: decision?["decision"] as? String,
        detail: decision?["detail"] as? String)
    } catch {
      return ConsentRead(ok: false)
    }
  }

  /// Ask the server to stop an agent task. The server answers with the task as
  /// it stands, which is what the card keeps showing.
  func cancelTask(id: String, brand: BrandKind) async -> Result<AgentTask, TaskFetchError> {
    await taskRequest(id: id, brand: brand, method: "POST", suffix: "cancel")
  }

  /// Ask the task service to run a failed task again, on the same id. This is
  /// the retry path's first choice: a re-run keeps the card's identity, its
  /// question and its place. A service without this route answers 404 and the
  /// caller re-runs the request through the route that created the task.
  func retryTask(id: String, brand: BrandKind) async -> Result<AgentTask, TaskFetchError> {
    await taskRequest(id: id, brand: brand, method: "POST", suffix: "retry")
  }

  /// Run a standing watch's next check now, rather than waiting for the
  /// schedule. The answer is the task as it stands.
  func checkWatch(id: String, brand: BrandKind) async -> Result<AgentTask, TaskFetchError> {
    await taskRequest(id: id, brand: brand, method: "POST", suffix: "check")
  }

  /// Stop a standing watch. Its last check stays; nothing more runs.
  func stopWatch(id: String, brand: BrandKind) async -> Result<AgentTask, TaskFetchError> {
    await taskRequest(id: id, brand: brand, method: "POST", suffix: "stop")
  }

  private func taskRequest(
    id: String, brand: BrandKind, method: String, suffix: String? = nil
  ) async -> Result<AgentTask, TaskFetchError> {
    var url = baseURL.appendingPathComponent("v1/tasks").appendingPathComponent(id)
    if let suffix { url.appendPathComponent(suffix) }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return .failure(.unavailable("The task address could not be built."))
    }
    components.queryItems = [URLQueryItem(name: "brand", value: brand.rawValue)]
    guard let finalURL = components.url else {
      return .failure(.unavailable("The task address could not be built."))
    }

    var request = URLRequest(url: finalURL)
    request.httpMethod = method
    request.timeoutInterval = min(timeout, 30)

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(.unavailable("The proxy gave no answer."))
      }
      if http.statusCode == 404 { return .failure(.notFound) }
      guard (200..<300).contains(http.statusCode) else {
        return .failure(.unavailable("The proxy answered \(http.statusCode)."))
      }
      let task = try JSONDecoder().decode(AgentTask.self, from: data)
      return .success(task)
    } catch is DecodingError {
      return .failure(.unavailable("The task answered in a shape this build does not understand."))
    } catch {
      return .failure(.unavailable("The task service is not reachable."))
    }
  }

  // MARK: Wire

  struct WireTurn: Encodable, Sendable {
    let role: String
    let content: String
  }

  private struct Request: Encodable {
    let message: String
    let digest: String
    let brand: String
    let sessionId: String
    let conversationId: String
    let pending: PendingTransferContext?
    let history: [WireTurn]
    /// The person's own city, from the address they saved. A search for shops
    /// should look where they are, not wherever the first result lives.
    let place: String?
  }

  private struct Response: Decodable {
    struct Specialist: Decodable {
      let id: String?
      let name: String?
      let role: String?
      let personality: String?
      let symbol: String?
      let assetName: String?
    }
    struct Action: Decodable {
      let type: String?
      let to: String?
      let from: String?
      let asset: String?
      let amountMinor: Int64?
      let missing: [String]?
      let topic: String?
      let providerConnected: Bool?
      let requirements: [String]?
      let focus: String?
      let knownRecipients: [String]?
      /// Agent-task acknowledgement. `taskId` is the poll handle, `title` and
      /// `status` are the acknowledgement the server sent with the turn.
      let taskId: String?
      let title: String?
      let status: String?
    }
    struct Reply: Decodable {
      let ok: Bool?
      let source: String?
      let say: String?
      let model: String?
      let latencyMs: Int?
      let detail: String?
    }

    let ok: Bool
    let detail: String?
    let decisionMode: String?
    let resolvedModel: String?
    let decisionLatencyMs: Int?
    let intent: String?
    let confidence: Double?
    let embeddedInstructionSignal: Double?
    let specialist: Specialist?
    let action: Action?
    let reply: Reply?

    func toResult(brand: BrandKind) -> OrchestrationResult {
      let specialist = AgentRoster.agent(brand: brand, id: self.specialist?.id)
      let mode: DecisionMode
      switch decisionMode {
      case "JEV_LIVE": mode = .jevLive(model: resolvedModel ?? "unknown")
      case "RULES_ONLY": mode = .rulesOnly
      default: mode = .unavailable
      }
      let action = ActionDecoder.decode(self.action)
      return OrchestrationResult(
        intent: Intent(rawValue: intent ?? "") ?? .ambiguous,
        decisionMode: mode,
        specialist: specialist,
        action: action,
        say: reply?.say ?? "",
        source: reply?.source ?? "unavailable",
        model: reply?.model ?? "unknown",
        latencyMs: reply?.latencyMs ?? 0,
        confidence: confidence,
        embeddedInstructionSignal: embeddedInstructionSignal,
        decisionModel: resolvedModel,
        decisionLatencyMs: decisionLatencyMs ?? 0
      )
    }
  }

  private enum ActionDecoder {
    static func decode(_ wire: Response.Action?) -> AgentAction {
      guard let wire, let raw = wire.type, let kind = AgentAction.Kind(rawValue: raw) else {
        return .reply
      }
      return AgentAction(
        kind: kind,
        to: wire.to,
        from: wire.from,
        assetCode: wire.asset,
        amountMinor: wire.amountMinor,
        missing: wire.missing ?? [],
        topic: wire.topic,
        providerConnected: wire.providerConnected,
        requirements: wire.requirements ?? [],
        focus: wire.focus,
        knownRecipients: wire.knownRecipients ?? [],
        taskId: wire.taskId,
        taskTitle: wire.title,
        taskStatus: wire.status
      )
    }
  }
}

// MARK: - Single specialist client

/// A short conversation with one named specialist, when the user opens one from
/// the roster. Same guarantee: prose only, no ledger access.
struct MiraAgentClient: Sendable {
  var baseURL: URL
  var timeout: TimeInterval

  init(baseURL: URL = JevProxyClient.defaultBaseURL, timeout: TimeInterval = 150) {
    self.baseURL = baseURL
    self.timeout = timeout
  }

  func ask(
    message: String,
    digest: String,
    brand: BrandKind,
    agentId: String,
    agentSessionId: String?,
    history: [MiraOrchestratorClient.WireTurn]
  ) async -> Result<AgentReply, AgentError> {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/agent"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    request.httpBody = try? JSONEncoder().encode(
      Request(
        message: message, digest: digest, brand: brand.rawValue, agentId: agentId,
        agentSessionId: agentSessionId, history: history))

    do {
      let (data, response) = try await URLSession.miraProxy.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return .failure(.unavailable("The proxy answered \(code)."))
      }
      let payload = try JSONDecoder().decode(Response.self, from: data)
      guard payload.ok, let reply = payload.reply, let say = reply.say, !say.isEmpty else {
        return .failure(.unavailable(payload.detail ?? "The specialist did not answer."))
      }
      return .success(
        AgentReply(
          say: say,
          model: payload.model ?? "unknown",
          latencyMs: payload.latencyMs ?? 0,
          agentSessionId: payload.agentSessionId,
          specialistName: payload.specialist?.name
        ))
    } catch {
      return .failure(
        .unavailable("The proxy is not reachable at \(baseURL.absoluteString)."))
    }
  }

  private struct Request: Encodable {
    let message: String
    let digest: String
    let brand: String
    let agentId: String
    let agentSessionId: String?
    let history: [MiraOrchestratorClient.WireTurn]
  }

  private struct Response: Decodable {
    struct Specialist: Decodable { let id: String?; let name: String?; let role: String? }
    struct Reply: Decodable { let say: String? }
    let ok: Bool
    let model: String?
    let latencyMs: Int?
    let detail: String?
    let agentSessionId: String?
    let specialist: Specialist?
    let reply: Reply?
  }
}

enum AgentError: Error, Equatable {
  case unavailable(String)

  var message: String {
    switch self {
    case .unavailable(let detail): return detail
    }
  }
}

/// A task fetch either produced the task, or says why it could not. `notFound`
/// is kept separate so a missing route can back off quietly rather than being
/// reported as a failed task.
enum TaskFetchError: Error, Equatable {
  case notFound
  case unavailable(String)
}

// MARK: - Pending transfer context

/// The carried context of an unfinished transfer request. It is only ever
/// context: the server still requires an explicit amount and the user still has
/// to confirm before anything moves.
struct PendingTransferContext: Encodable, Sendable {
  var kind: String = "transfer"
  var to: String?
  var asset: String?
  var amountMinor: Int64?
}
