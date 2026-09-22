import Foundation

// MARK: - Relay records

/// A settled transfer as the relay ledger reports it.
struct RelayTransfer: Sendable, Identifiable, Hashable {
  let id: String
  let idempotencyKey: String
  let from: String
  let to: String
  let assetCode: String
  /// Amount in the asset's own minor units, so a six-decimal token is exact.
  let amountMinor: Int64
  let note: String
  let at: Int
  let status: String

  var asset: Asset? { Asset.all.first { $0.code == assetCode } }

  var receiptLine: String {
    guard let asset else { return "\(assetCode) \(amountMinor)" }
    return Money(minorUnits: amountMinor, currency: asset).display
  }
}

struct RelayAccountState: Sendable {
  let identity: String?
  let known: Bool
  let balances: [String: Int64]
  let transfers: [RelayTransfer]
}

enum RelayOutcome: Sendable {
  case settled(RelayTransfer)
  case duplicate(RelayTransfer)
  case rejected(code: String, detail: String)
  case unreachable(String)

  var transfer: RelayTransfer? {
    switch self {
    case .settled(let t), .duplicate(let t): return t
    case .rejected, .unreachable: return nil
    }
  }

  var isSuccess: Bool { transfer != nil }

  var userMessage: String? {
    switch self {
    case .settled, .duplicate: return nil
    case .rejected(let code, let detail):
      switch code {
      case "insufficient_funds": return "The ledger refused this: \(detail)"
      case "invalid_amount": return "That amount is not a valid positive amount."
      case "unsupported_asset": return "This build does not support that currency or asset."
      case "unknown_identity": return "That recipient is not in your contacts yet."
      case "same_identity": return "Sender and recipient are the same identity."
      case "amount_exceeds_limit": return "That amount is above this build's limit."
      case "idempotency_key_required": return "This transfer is missing its idempotency key."
      default: return "The ledger refused this transfer: \(detail)"
      }
    case .unreachable(let detail): return detail
    }
  }
}

// MARK: - Client

/// The demo's "network".
///
/// Both apps talk to the same local proxy, so it doubles as the rail between
/// them. The durable ledger behind it is authoritative: it owns the balance
/// limits and the idempotency, so a retry or a repeated poll can never move
/// money twice. Still simulated, and still not a bank.
struct TransferRelayClient: Sendable {
  var baseURL: URL
  var timeout: TimeInterval

  init(baseURL: URL = JevProxyClient.defaultBaseURL, timeout: TimeInterval = 12) {
    self.baseURL = baseURL
    self.timeout = timeout
  }

  /// Move simulated value. The same `idempotencyKey` is always the same transfer.
  func transfer(
    idempotencyKey: String,
    from: String,
    to: String,
    asset: Asset,
    amount: Money,
    note: String
  ) async -> RelayOutcome {
    guard amount.currency == asset, amount.minorUnits > 0 else {
      return .rejected(code: "invalid_amount", detail: "The amount must be positive.")
    }
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/relay/transfer"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    request.httpBody = try? JSONEncoder().encode(
      Outbound(
        idempotencyKey: idempotencyKey, from: from, to: to, asset: asset.code,
        amountMinor: amount.minorUnits, note: note))

    do {
      let (data, response) = try await URLSession.miraProxy.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return .unreachable("The relay answered \((response as? HTTPURLResponse)?.statusCode ?? -1).")
      }
      let payload = try JSONDecoder().decode(OutboundResponse.self, from: data)
      if payload.ok, let transfer = payload.transfer {
        return payload.duplicate == true ? .duplicate(transfer) : .settled(transfer)
      }
      return .rejected(
        code: payload.error ?? "relay_failure",
        detail: payload.detail ?? "The relay refused this transfer.")
    } catch {
      return .unreachable(
        "Mira cannot reach your other app right now. Open it once and try again.")
    }
  }

  /// The authoritative ledger state for an identity.
  func state(identity: String) async -> RelayAccountState? {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("v1/relay/state"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "identity", value: identity)]
    guard let url = components?.url else { return nil }

    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    guard let (data, response) = try? await URLSession.miraProxy.data(for: request),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let payload = try? JSONDecoder().decode(StateResponse.self, from: data)
    else { return nil }

    return RelayAccountState(
      identity: payload.identity, known: payload.known ?? false,
      balances: payload.balances ?? [:], transfers: payload.transfers ?? [])
  }

  /// Transfers involving an identity. `since` is a relay timestamp.
  func transfers(identity: String, since: Int = 0) async -> [RelayTransfer] {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("v1/relay/transfers"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "identity", value: identity),
      URLQueryItem(name: "since", value: String(since)),
    ]
    guard let url = components?.url else { return [] }

    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    guard let (data, response) = try? await URLSession.miraProxy.data(for: request),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let payload = try? JSONDecoder().decode(TransfersResponse.self, from: data)
    else { return [] }
    return payload.transfers ?? []
  }

  // MARK: Wire

  private struct Outbound: Encodable {
    let idempotencyKey: String
    let from: String
    let to: String
    let asset: String
    let amountMinor: Int64
    let note: String
  }

  private struct OutboundResponse: Decodable {
    let ok: Bool
    let duplicate: Bool?
    let error: String?
    let detail: String?
    let transfer: RelayTransfer?
  }

  private struct StateResponse: Decodable {
    let identity: String?
    let known: Bool?
    let balances: [String: Int64]?
    let transfers: [RelayTransfer]?
  }

  private struct TransfersResponse: Decodable {
    let transfers: [RelayTransfer]?
  }
}

// RelayTransfer decodes straight from the durable ledger's JSON.
extension RelayTransfer: Decodable {
  enum CodingKeys: String, CodingKey {
    case id, idempotencyKey, from, to, asset, amountMinor, note, at, status
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    idempotencyKey = (try? c.decode(String.self, forKey: .idempotencyKey)) ?? id
    from = try c.decode(String.self, forKey: .from)
    to = (try? c.decode(String.self, forKey: .to)) ?? "unknown"
    assetCode = try c.decode(String.self, forKey: .asset)
    amountMinor = try c.decode(Int64.self, forKey: .amountMinor)
    note = (try? c.decode(String.self, forKey: .note)) ?? ""
    at = (try? c.decode(Int.self, forKey: .at)) ?? 0
    status = (try? c.decode(String.self, forKey: .status)) ?? "settled"
  }
}
