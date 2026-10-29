import Foundation
import OSLog

nonisolated let gatewayLog = Logger(subsystem: "com.example.ChatCall", category: "gateway")

/// Every `/v4` answer carries this outcome, even on HTTP 200.
nonisolated struct Envelope: Decodable, Sendable {
  let errorCode: Int
  let errorInfo: String

  private enum CodingKeys: String, CodingKey { case errorCode = "ErrorCode", errorInfo = "ErrorInfo" }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    errorCode = try values.decodeIfPresent(Int.self, forKey: .errorCode) ?? 0
    errorInfo = try values.decodeIfPresent(String.self, forKey: .errorInfo) ?? ""
  }
}

/// Authorised `POST /v4/<operation>` with the bearer token, request-id check, bounded retry and envelope.
actor GatewayClient {
  /// Codes the contract marks retryable (0.5 §4.2); everything else is permanent.
  static let retryableCodes: Set<Int> = [
    60007, 60008, 60020, 10002, 50004, 40006, 70500, 91000, 20004, 20005
  ]
  private static let maxRetries = 5
  private static let revokedCode = 70009

  private let configuration: GatewayConfiguration
  private let tokens: any AccessTokenProvider
  private let transport: any HTTPTransport
  private let sleep: @Sendable (Duration) async -> Void

  init(
    configuration: GatewayConfiguration, tokens: any AccessTokenProvider,
    transport: any HTTPTransport = URLSession.shared,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.configuration = configuration
    self.tokens = tokens
    self.transport = transport
    self.sleep = sleep
  }

  func post<Response: Decodable & Sendable>(
    _ operation: String, body: some Encodable & Sendable
  ) async throws -> Response {
    let payload = try JSONEncoder().encode(body)
    var attempt = 0
    var refreshed = false
    while true {
      try Task.checkCancellation()
      let token = try await validToken()
      let data: Data
      let response: HTTPURLResponse
      do {
        (data, response) = try await send(operation, payload: payload, token: token)
      } catch let error as GatewayError where error == .transport {
        attempt += 1
        guard attempt <= Self.maxRetries else { throw error }
        await sleep(Self.backoff(attempt))
        continue
      }
      guard let requestID = response.value(forHTTPHeaderField: "X-Request-Id") else {
        gatewayLog.error("\(operation, privacy: .public): response without X-Request-Id")
        throw GatewayError.missingRequestID
      }
      gatewayLog.notice(
        "\(operation, privacy: .public) ← HTTP \(response.statusCode) request-id=\(requestID, privacy: .public)"
      )
      switch response.statusCode {
      case 200..<300:
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let code = envelope?.errorCode ?? 0
        if code == 0 {
          guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GatewayError.invalidResponse
          }
          return decoded
        }
        attempt += 1
        guard Self.retryableCodes.contains(code), attempt <= Self.maxRetries else {
          throw GatewayError.envelope(code: code, info: envelope?.errorInfo ?? "")
        }
        await sleep(Self.backoff(attempt))
      case 401:
        if Self.errorCode(in: data) == Self.revokedCode { throw GatewayError.revoked }
        guard !refreshed else { throw GatewayError.unauthorized }
        refreshed = true
        await tokens.invalidate(token)
      case 403:
        throw GatewayError.forbidden
      case 429:
        attempt += 1
        guard attempt <= Self.maxRetries else { throw GatewayError.rateLimited }
        await sleep(Self.retryAfter(response) ?? Self.backoff(attempt))
      case 500...:
        attempt += 1
        guard attempt <= Self.maxRetries else { throw GatewayError.server(response.statusCode) }
        await sleep(Self.backoff(attempt))
      default:
        throw GatewayError.invalidResponse
      }
    }
  }

  private func validToken() async throws -> AccessToken {
    do {
      return try await tokens.validToken()
    } catch AuthError.revoked {
      throw GatewayError.revoked
    } catch AuthError.invalidCredentials {
      throw GatewayError.unauthorized
    } catch AuthError.invalidResponse {
      throw GatewayError.invalidResponse
    } catch AuthError.unavailable {
      throw GatewayError.transport
    }
  }

  private func send(_ operation: String, payload: Data, token: AccessToken) async throws -> (
    Data, HTTPURLResponse
  ) {
    var request = URLRequest(url: configuration.httpBase.appending(path: "v4/\(operation)"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = payload
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
    do {
      return try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      gatewayLog.error("\(operation, privacy: .public): transport error")
      throw GatewayError.transport
    }
  }

  /// Jittered exponential backoff, 500 ms base, capped at 30 s.
  static func backoff(_ attempt: Int) -> Duration {
    let ceiling = min(30_000, 500 * (1 << min(attempt - 1, 10)))
    return .milliseconds(Int.random(in: ceiling / 2...ceiling))
  }

  private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
    guard let text = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(text),
      seconds >= 0
    else { return nil }
    return .seconds(min(seconds, 30))
  }

  private static func errorCode(in data: Data) -> Int {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
    return (body["ErrorCode"] as? Int) ?? (body["code"] as? Int) ?? 0
  }
}
