import Foundation
import Security

// MARK: - Where the proxy lives, and how a build proves it may call it

/// The proxy configuration an installed bundle carries in its Info.plist.
///
/// Both values are written at install time by `scripts/point-app.sh`, never
/// compiled in: the address because the hosted proxy is not the same thing as
/// the Mac on the desk, and the key because a credential must not live in the
/// repository or in the app binary. Every reader below is injectable so the
/// precedence can be pinned by tests rather than only by reading the code.
enum MiraProxyConfig {
  private struct SavedSimulatorProxy: Codable {
    let url: String
    let key: String
  }

  /// Xcode test runs reinstall the app without the install-time Info.plist
  /// values. Keep the last configured simulator endpoint in its private data
  /// container so the next launch does not fall back to the Mac's loopback.
  /// The Keychain copy is preferred when the test build has the same signature.
  private static let runtimeInfo: [String: Any] = {
    let installed = Bundle.main.infoDictionary ?? [:]
    #if targetEnvironment(simulator)
    if let key = key(info: installed) {
      let address = url(info: installed)?.absoluteString
        ?? legacyHost(info: installed).map { "http://\($0):8791" }
      if let address {
        saveSimulatorProxy(SavedSimulatorProxy(url: address, key: key))
        return installed
      }
    }
    if let saved = loadSimulatorProxy() ?? loadSimulatorProxyFile() {
      return ["MIRAProxyURL": saved.url, "MIRAProxyKey": saved.key]
    }
    #endif
    return installed
  }()

  private static let simulatorProxyAccount = "configured-proxy"

  private static var simulatorProxyFile: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("MiraProxyConfig.json")
  }

  private static func loadSimulatorProxyFile() -> SavedSimulatorProxy? {
    guard let file = simulatorProxyFile, let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(SavedSimulatorProxy.self, from: data)
  }

  private static func loadSimulatorProxy() -> SavedSimulatorProxy? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.codeaustral.mira.simulator-proxy",
      kSecAttrAccount as String: simulatorProxyAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(SavedSimulatorProxy.self, from: data)
  }

  private static func saveSimulatorProxy(_ proxy: SavedSimulatorProxy) {
    guard let data = try? JSONEncoder().encode(proxy) else { return }
    if let file = simulatorProxyFile {
      try? FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.codeaustral.mira.simulator-proxy",
      kSecAttrAccount as String: simulatorProxyAccount,
    ]
    let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard updated == errSecItemNotFound else { return }
    var created = query
    created[kSecValueData as String] = data
    created[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(created as CFDictionary, nil)
  }

  /// A full URL, used exactly as written, e.g. `https://mira.codeaustral.com`.
  static var hostedURL: URL? { url(info: runtimeInfo) }

  /// The legacy local-network host, rendered as `http://<host>:8791`.
  static var legacyHost: String? { legacyHost(info: runtimeInfo) }

  /// The key the deployed proxy asks for. Absent in a development build.
  static var key: String? { key(info: runtimeInfo) }

  static var runtimeBaseURL: URL { baseURL(info: runtimeInfo) }

  /// The hosted URL wins because a build that names a full address is a build
  /// that means it; the legacy host is the local-network fallback; loopback is
  /// what remains for a simulator, where 127.0.0.1 *is* the Mac.
  static func baseURL(info: [String: Any]) -> URL {
    if let hosted = url(info: info) { return hosted }
    if let host = legacyHost(info: info), let url = URL(string: "http://\(host):8791") {
      return url
    }
    return URL(string: "http://127.0.0.1:8791")!
  }

  static func url(info: [String: Any]) -> URL? {
    guard let raw = info["MIRAProxyURL"] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }

  static func legacyHost(info: [String: Any]) -> String? {
    guard let raw = info["MIRAProxyHost"] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // A host, not an address: a value carrying a scheme or a path belongs in
    // MIRAProxyURL, and accepting it here would build a nonsense URL.
    guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" ") else { return nil }
    return trimmed
  }

  static func key(info: [String: Any]) -> String? {
    guard let raw = info["MIRAProxyKey"] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - The proxy transport

/// One session for every proxy request, so the key is attached in exactly one
/// place and no call site can forget it. Non-proxy traffic — the direct model
/// call in `StandaloneAgent` and the public rate source in `LiveRates` — stays
/// on `.shared`, which never carries the proxy credential anywhere else.
enum MiraProxySession {
  static let shared: URLSession = make(key: MiraProxyConfig.key)

  /// Exposed so tests can pin the configured and the unconfigured case without
  /// an installed bundle, over a stub transport. The configuration is passed in
  /// rather than created here for exactly that reason.
  static func make(key: String?, configuration: URLSessionConfiguration = .default) -> URLSession {
    if let key {
      configuration.httpAdditionalHeaders = ["x-mira-key": key]
    }
    return URLSession(configuration: configuration)
  }
}

extension URLSession {
  /// The session a proxy call must use, wherever it lives.
  static var miraProxy: URLSession { MiraProxySession.shared }
}

// MARK: - Jev front door

/// Talks to the server-side decision proxy.
///
/// The app never holds a Jev credential: the key lives in the proxy's
/// environment. If the proxy is not running, the app degrades to rules and says
/// so, rather than pretending a model answered.
struct JevProxyClient: DecisionProvider {
  let baseURL: URL
  let timeout: TimeInterval

  init(baseURL: URL = JevProxyClient.defaultBaseURL, timeout: TimeInterval = 12) {
    self.baseURL = baseURL
    self.timeout = timeout
  }

  /// Where the proxy lives.
  ///
  /// On the simulator that is the Mac's own loopback. On a phone, `127.0.0.1`
  /// is the *phone*, so a device build reads its address from the installed
  /// bundle — `MIRAProxyURL` for the hosted proxy, the legacy `MIRAProxyHost`
  /// for a Mac on the local network — and falls back to loopback when neither
  /// is present (a simulator build, or a phone with no proxy nearby, where the
  /// app then reports the model as unreachable rather than inventing an answer).
  static var defaultBaseURL: URL {
    MiraProxyConfig.runtimeBaseURL
  }

  func classify(state: String, sessionId: String) async -> DecisionResult {
    let started = Date()
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/decide"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    request.httpBody = try? JSONEncoder().encode(DecideRequest(state: state, sessionId: sessionId))

    do {
      let (data, response) = try await URLSession.miraProxy.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return .unavailable(
          detail: "The decision proxy answered \(code). Falling back to explicit controls.",
          latencyMs: milliseconds(since: started)
        )
      }
      let payload = try JSONDecoder().decode(DecideResponse.self, from: data)
      return payload.toResult()
    } catch {
      return .unavailable(
        detail:
          "The decision proxy is not reachable at \(baseURL.absoluteString). Rules handled this instead.",
        latencyMs: milliseconds(since: started)
      )
    }
  }

  private func milliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
  }

  /// Reads the proxy's declared capability without making a model call, so the
  /// mode strip can report the truth before the first decision is made.
  func availabilityMode() async -> DecisionMode? {
    var request = URLRequest(url: baseURL.appendingPathComponent("health"))
    request.timeoutInterval = 4
    guard let (data, response) = try? await URLSession.miraProxy.data(for: request),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let payload = try? JSONDecoder().decode(HealthResponse.self, from: data)
    else { return nil }

    return payload.defaultDecisionMode == "JEV_LIVE"
      ? .jevLive(model: payload.modelRequested ?? "jev-1.13.0")
      : .rulesOnly
  }

  private struct HealthResponse: Decodable {
    let defaultDecisionMode: String?
    let modelRequested: String?
  }

  // MARK: Wire format

  private struct DecideRequest: Encodable {
    let state: String
    let sessionId: String
  }

  private struct DecideResponse: Decodable {
    struct Choice: Decodable {
      let type: String?
      let choice: String?
      let confidence: Double?
      let probabilities: [String: Double]?
    }
    struct Score: Decodable {
      let type: String?
      let score: Double?
      let confidence: Double?
    }
    struct Noul: Decodable {
      let type: String?
      let noul: Double?
    }

    let decisionMode: String?
    let resolvedModel: String?
    let latencyMs: Int?
    let detail: String?
    let routed: String?
    let answers: Answers?

    struct Answers: Decodable {
      let intent: Choice?
      let needsClarification: Noul?
      let containsEmbeddedInstruction: Noul?

      enum CodingKeys: String, CodingKey {
        case intent
        case needsClarification = "needs_clarification"
        case containsEmbeddedInstruction = "contains_embedded_instruction"
      }
    }

    func toResult() -> DecisionResult {
      let mode: DecisionMode
      switch decisionMode {
      case "JEV_LIVE":
        mode = .jevLive(model: resolvedModel ?? "unknown")
      case "RULES_ONLY":
        mode = .rulesOnly
      default:
        mode = .unavailable
      }

      let rawIntent = answers?.intent?.choice ?? routed ?? "ambiguous"
      return DecisionResult(
        intent: Intent(rawValue: rawIntent) ?? .ambiguous,
        confidence: answers?.intent?.confidence,
        probabilities: answers?.intent?.probabilities ?? [:],
        needsClarification: answers?.needsClarification?.noul,
        embeddedInstructionSignal: answers?.containsEmbeddedInstruction?.noul,
        mode: mode,
        resolvedModel: resolvedModel,
        latencyMs: latencyMs ?? 0,
        detail: detail ?? ""
      )
    }
  }
}

// MARK: - Offline fallback

/// Fully offline decision provider. Deterministic, transparent, and good enough
/// that the entire demo works with no network and no key at all.
struct RulesDecisionProvider: DecisionProvider {
  init() {}

  func classify(state: String, sessionId: String) async -> DecisionResult {
    let text = state.lowercased()
    func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

    var intent: Intent = .ambiguous
    var signal: Double = 0.05

    if has("ignore your limits", "ignore previous", "disregard", "system prompt", "override your") {
      intent = .ambiguous
      signal = 0.95
    } else if has(
      "how much can i spend", "weekly budget", "this week", "budget", "plan", "allocate")
    {
      intent = .budget
    } else if has("pix", "pay ", "send", "invoice", "qr code", "transfer") {
      intent = .preparePayment
    } else if has("receive", "account details", "deposit", "wire", "ach ") {
      intent = .receive
    } else if has("reserve", "safety net", "earmark", "set aside") {
      intent = .reserve
    } else if has("earn", "yield", "interest", "apy", "invest") {
      intent = .earnInformation
    } else if has("card", "freeze", "blocked") {
      intent = .cardHelp
    } else if has("balance", "total", "how much do i have", "funds") {
      intent = .balance
    } else if has("help", "support", "human", "talk to someone") {
      intent = .support
    }

    return DecisionResult(
      intent: intent,
      confidence: 1.0,
      probabilities: [intent.rawValue: 1.0],
      needsClarification: intent == .ambiguous ? 0.8 : 0.2,
      embeddedInstructionSignal: signal,
      mode: .rulesOnly,
      resolvedModel: nil,
      latencyMs: 0,
      detail: "Decided by the deterministic rules adapter. No model was called."
    )
  }
}
