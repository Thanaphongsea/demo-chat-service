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

nonisolated struct Session: Equatable, Sendable {
  let user: User
  let signedInAt: Date
}

nonisolated enum AuthError: Error, Equatable, Sendable {
  case invalidCredentials
}
