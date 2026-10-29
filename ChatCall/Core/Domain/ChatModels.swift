import Foundation

nonisolated enum ConversationKind: String, Codable, Sendable { case direct, group }
nonisolated enum DeliveryState: String, Codable, Sendable { case sending, sent, delivered }
nonisolated enum ChatError: Error, Equatable, Sendable {
  case invalidMembers, groupNameRequired, emptyMessage, conversationNotFound, userNotFound
}

nonisolated struct Message: Identifiable, Equatable, Codable, Sendable {
  let id: MessageID
  let conversationID: ConversationID
  let senderID: UserID
  let text: String
  let sentAt: Date
  let deliveryState: DeliveryState
}

nonisolated struct Conversation: Identifiable, Equatable, Sendable {
  let id: ConversationID
  let kind: ConversationKind
  let name: String
  let memberIDs: [UserID]
  let unreadCount: Int
  let lastMessage: Message?
  let updatedAt: Date

  init(
    id: ConversationID, kind: ConversationKind, name: String, memberIDs: [UserID],
    unreadCount: Int = 0, lastMessage: Message? = nil, updatedAt: Date
  ) throws {
    guard Set(memberIDs).count == memberIDs.count,
      kind == .direct ? memberIDs.count == 2 : !memberIDs.isEmpty
    else { throw ChatError.invalidMembers }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard kind != .group || !trimmedName.isEmpty else { throw ChatError.groupNameRequired }
    self.id = id
    self.kind = kind
    self.name = trimmedName
    self.memberIDs = memberIDs
    self.unreadCount = unreadCount
    self.lastMessage = lastMessage
    self.updatedAt = updatedAt
  }
}

nonisolated enum ChatEvent: Equatable, Sendable {
  case conversationUpdated(Conversation)
  case messageInserted(Message)
  case deliveryChanged(messageID: MessageID, conversationID: ConversationID, state: DeliveryState)
}
