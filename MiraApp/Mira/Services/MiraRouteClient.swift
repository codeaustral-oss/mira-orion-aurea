import Foundation

// MARK: - Where does the answer live?
//
// One call to the proxy's route endpoint, which asks Jev a typed question: does
// the answer sit in the app's own records, in a short reply, or on the web?
//
// It is deliberately tiny and deliberately optional. A failure returns nil and
// the app carries on with its own deterministic path — the router is an
// accelerator, never a dependency. Nothing here moves money.
//
// `refuse` is the fifth answer, for a message that tries to change the
// assistant's own rules, identity or limits: the proxy labels it and the app
// answers with `MiraRouteClient.refusalLine`, never with a model-written line.

/// A policy answer to a message, and where the proxy said the answer lives.
struct RoutedIntent: Sendable {
  var route: String
  /// Which of the app's own records holds the answer, when it is an instant one.
  var needs: String
  /// Why a `refuse` route was chosen ("instruction_override"), when the proxy says.
  var reason: String?
  var routeConfidence: Double?
  var liveWeb: Double?
  var latencyMs: Int
}

/// The route reader as a protocol, so the session's refusal path can be driven
/// in tests without a live proxy.
protocol MiraRouteProviding: Sendable {
  func route(_ message: String, baseURL: URL) async -> RoutedIntent?
}

final class MiraRouteClient: MiraRouteProviding, @unchecked Sendable {
  static let shared = MiraRouteClient()

  /// The one refusal line — the same words the proxy's deterministic guard
  /// carries. It is never rewritten by a model, and it never repeats the
  /// message back.
  static let refusalLine =
    "I won't do that. I can't change my own rules or raise limits, and nothing moves without your approval."

  private let timeout: TimeInterval = 2.5

  func route(_ message: String, baseURL: URL) async -> RoutedIntent? {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/route"))
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["message": message])

    do {
      let (data, response) = try await URLSession.miraProxy.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        root["ok"] as? Bool == true,
        let route = root["route"] as? String
      else { return nil }

      return RoutedIntent(
        route: route,
        needs: (root["needs"] as? String) ?? "none",
        reason: root["reason"] as? String,
        routeConfidence: root["routeConfidence"] as? Double,
        liveWeb: root["liveWeb"] as? Double,
        latencyMs: (root["latencyMs"] as? Int) ?? 0
      )
    } catch {
      // No router today: the app's own rules still work.
      return nil
    }
  }
}
