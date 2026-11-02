import Foundation
import OSLog

nonisolated let callLog = Logger(subsystem: "com.example.ChatCall", category: "call")

/// The VoIP origin: `/api/calls`, `/api/rooms`, `/api/ice` and the media socket share it.
/// Defaults to the dev service; override with `-voipURL` (HTTPS for a real device: `127.0.0.1` on an
/// iPhone is the iPhone itself).
nonisolated struct VoIPConfiguration: Equatable, Sendable {
  let baseURL: URL

  init(baseURL: URL) { self.baseURL = baseURL }

  /// From `Config/Local.xcconfig` via Info.plist (`unset.invalid` if unset); `-voipURL` overrides it at launch.
  static let dev = VoIPConfiguration(
    baseURL: BuildConfiguration.url(forInfoKey: "ChatCallVoIPBaseURL"))

  /// Launch-argument override on top of `dev`; an invalid override is ignored.
  init(defaults: UserDefaults = .standard) {
    let url = defaults.string(forKey: "voipURL").flatMap(URL.init(string:)).flatMap {
      ($0.scheme == "https" || $0.scheme == "http") && $0.host != nil ? $0 : nil
    }
    self.init(baseURL: url ?? Self.dev.baseURL)
  }
}

nonisolated enum VoIPError: Error, Equatable, Sendable {
  case unauthorized
  case revoked
  case forbidden
  /// The call no longer exists; the server may attach its last known state.
  case notFound(call: WireCallInfo?)
  /// Busy, idempotency conflict or an invalid transition; read the attached state again.
  case conflict(call: WireCallInfo?, message: String)
  case badRequest(message: String)
  case rateLimited
  case server(Int)
  case transport
  case invalidResponse
}

/// Authorised calls to the VoIP REST API with bounded retry. A retried request keeps its exact body and headers.
actor VoIPClient {
  private static let maxRetries = 5

  private let configuration: VoIPConfiguration
  private let tokens: any AccessTokenProvider
  private let transport: any HTTPTransport
  private let sleep: @Sendable (Duration) async -> Void

  init(
    configuration: VoIPConfiguration, tokens: any AccessTokenProvider,
    transport: any HTTPTransport = URLSession.shared,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.configuration = configuration
    self.tokens = tokens
    self.transport = transport
    self.sleep = sleep
  }

  func create(_ request: CreateCallRequest) async throws -> WireCallInfo {
    let body = try JSONEncoder().encode(request)
    return try await send(
      method: "POST", path: ["api", "calls"], query: [], body: body,
      headers: ["Idempotency-Key": request.idempotencyKey])
  }

  func inbox(peer: UserID) async throws -> WireInbox {
    try await send(
      method: "GET", path: ["api", "calls"], query: [URLQueryItem(name: "peer_id", value: peer.rawValue)])
  }

  func call(id: String, peer: UserID) async throws -> WireCallInfo {
    try await send(
      method: "GET", path: ["api", "calls", id],
      query: [URLQueryItem(name: "peer_id", value: peer.rawValue)])
  }

  func perform(_ action: CallAction, id: String, peer: UserID) async throws -> WireCallInfo {
    let body = try JSONEncoder().encode(ActionRequest(peerID: peer.rawValue))
    return try await send(
      method: "POST", path: ["api", "calls", id, action.rawValue], query: [], body: body)
  }

  /// Opens the media room for an accepted call. The answer's id is internal; keep using the logical room id.
  func prepareRoom(callID: String, roomID: String) async throws {
    let body = try JSONEncoder().encode(PrepareRoomRequest(roomID: roomID))
    let _: WireRoom = try await send(
      method: "POST", path: ["api", "rooms"], query: [URLQueryItem(name: "call_id", value: callID)],
      body: body)
  }

  func iceServers() async throws -> [WireICEServer] {
    let config: WireICEConfig = try await send(method: "GET", path: ["api", "ice"], query: [])
    return config.servers
  }

  /// The media socket URL and a current token for its `Authorization` header (never put in the URL).
  func mediaSocket(roomID: String, callID: String, peer: UserID) async throws -> (
    url: URL, token: String
  ) {
    let token = try await validToken()
    var parts = URLComponents(
      url: configuration.baseURL.appending(path: "api").appending(path: "ws"),
      resolvingAgainstBaseURL: false)
    parts?.scheme = configuration.baseURL.scheme == "https" ? "wss" : "ws"
    parts?.queryItems = [
      URLQueryItem(name: "room_id", value: roomID), URLQueryItem(name: "peer_id", value: peer.rawValue),
      URLQueryItem(name: "call_id", value: callID)
    ]
    guard let url = parts?.url else { throw VoIPError.invalidResponse }
    return (url, token.value)
  }

  // MARK: transport

  private func send<Response: Decodable & Sendable>(
    method: String, path: [String], query: [URLQueryItem], body: Data? = nil,
    headers: [String: String] = [:]
  ) async throws -> Response {
    var attempt = 0
    var refreshed = false
    while true {
      try Task.checkCancellation()
      let token = try await validToken()
      let request = makeRequest(
        method: method, path: path, query: query, body: body, headers: headers, token: token)
      let data: Data
      let response: HTTPURLResponse
      do {
        (data, response) = try await transport.send(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch {
        attempt += 1
        guard attempt <= Self.maxRetries else { throw VoIPError.transport }
        await sleep(GatewayClient.backoff(attempt))
        continue
      }
      callLog.notice(
        "\(method, privacy: .public) \(path.joined(separator: "/"), privacy: .public) ← HTTP \(response.statusCode)"
      )
      switch response.statusCode {
      case 200..<300:
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
          throw VoIPError.invalidResponse
        }
        return decoded
      case 401:
        guard !refreshed else { throw VoIPError.unauthorized }
        refreshed = true
        await tokens.invalidate(token)
      case 403: throw VoIPError.forbidden
      case 404: throw VoIPError.notFound(call: Self.errorBody(data).call)
      case 409:
        let body = Self.errorBody(data)
        throw VoIPError.conflict(call: body.call, message: body.message)
      case 400, 422: throw VoIPError.badRequest(message: Self.errorBody(data).message)
      case 429:
        attempt += 1
        guard attempt <= Self.maxRetries else { throw VoIPError.rateLimited }
        await sleep(Self.retryAfter(response) ?? GatewayClient.backoff(attempt))
      case 500...:
        attempt += 1
        guard attempt <= Self.maxRetries else { throw VoIPError.server(response.statusCode) }
        await sleep(GatewayClient.backoff(attempt))
      default:
        throw VoIPError.invalidResponse
      }
    }
  }

  private func validToken() async throws -> AccessToken {
    do {
      return try await tokens.validToken()
    } catch AuthError.revoked {
      throw VoIPError.revoked
    } catch AuthError.invalidCredentials {
      throw VoIPError.unauthorized
    } catch AuthError.invalidResponse {
      throw VoIPError.invalidResponse
    } catch AuthError.unavailable {
      throw VoIPError.transport
    }
  }

  private func makeRequest(
    method: String, path: [String], query: [URLQueryItem], body: Data?,
    headers: [String: String], token: AccessToken
  ) -> URLRequest {
    var url = configuration.baseURL
    for component in path { url = url.appending(path: component) }
    if !query.isEmpty { url = url.appending(queryItems: query) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 15
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
    return request
  }

  private struct ErrorBody: Decodable {
    let error: String?
    let call: WireCallInfo?
  }

  private static func errorBody(_ data: Data) -> (message: String, call: WireCallInfo?) {
    let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
    return (body?.error ?? "", body?.call)
  }

  private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
    guard let text = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(text),
      seconds >= 0
    else { return nil }
    return .seconds(min(seconds, 30))
  }
}
