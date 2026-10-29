import Foundation

nonisolated struct EntityID<Tag: Sendable>: RawRepresentable, Hashable, Codable, Sendable {
  let rawValue: String
  init(rawValue: String) { self.rawValue = rawValue }
  init(_ rawValue: String) { self.rawValue = rawValue }
}

nonisolated enum UserTag: Sendable {}
nonisolated enum ConversationTag: Sendable {}
nonisolated enum MessageTag: Sendable {}
nonisolated enum CallTag: Sendable {}
typealias UserID = EntityID<UserTag>
typealias ConversationID = EntityID<ConversationTag>
typealias MessageID = EntityID<MessageTag>
typealias CallID = EntityID<CallTag>

nonisolated struct User: Identifiable, Hashable, Codable, Sendable {
  let id: UserID
  let displayName: String
  let initials: String
}

nonisolated struct Credentials: Equatable, Sendable {
  let identity: String
  let password: String
}

/// Bearer token for the identity service. Never printed or logged.
nonisolated struct AccessToken: Equatable, Sendable {
  let value: String
  let expiresAt: Date
}

extension AccessToken: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "AccessToken(<redacted>)" }
  var debugDescription: String { description }
}

nonisolated struct Session: Equatable, Sendable {
  let user: User
  let signedInAt: Date
  /// Nil for mock sessions; always present for a live identity session.
  let accessToken: AccessToken?

  init(user: User, signedInAt: Date, accessToken: AccessToken? = nil) {
    self.user = user
    self.signedInAt = signedInAt
    self.accessToken = accessToken
  }
}

nonisolated enum AuthError: Error, Equatable, Sendable {
  case invalidCredentials
  /// Network failure, rate limiting, or a server error; the credentials were not rejected.
  case unavailable
  case invalidResponse
  /// The server ended this session (kicked); refreshing cannot succeed, so sign in again.
  case revoked
}
