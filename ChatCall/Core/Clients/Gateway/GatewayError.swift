import Foundation

nonisolated enum GatewayError: Error, Equatable, Sendable {
  /// The session is gone or the token was rejected twice; sign in again.
  case unauthorized
  /// The server ended this session (code 70009); sign out and do not retry.
  case revoked
  case forbidden
  case rateLimited
  /// HTTP 5xx after the bounded retries.
  case server(Int)
  /// A non-zero `ErrorCode` in the response envelope.
  case envelope(code: Int, info: String)
  case transport
  case invalidResponse
  /// The response lacks `X-Request-Id`, so it did not pass the gateway.
  case missingRequestID
}
