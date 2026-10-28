import Foundation

nonisolated struct MockSeed: Sendable {
  static let date = Date(timeIntervalSince1970: 1_700_000_000)
  static let currentUser = User(id: UserID("user-me"), displayName: "You", initials: "YO")
  static let invalidCredentials = Credentials(identity: "invalid", password: "invalid")
  let users: [User]
  let conversations: [Conversation]
  let messages: [Message]

  static var standard: MockSeed {
    let ava = User(id: UserID("user-ava"), displayName: "Ava Chen", initials: "AC")
    let noah = User(id: UserID("user-noah"), displayName: "Noah Williams", initials: "NW")
    let extras = (1...15).map {
      User(id: UserID("user-\($0)"), displayName: "Teammate \($0)", initials: "T\($0)")
    }
    let directMessage = Message(
      id: MessageID("message-ava-1"),
      conversationID: ConversationID("conversation-ava"), senderID: ava.id,
      text: "Ready to catch up?", sentAt: date, deliveryState: .delivered)
    let groupMessage = Message(
      id: MessageID("message-team-1"),
      conversationID: ConversationID("conversation-team"), senderID: noah.id,
      text: "See you on the call.", sentAt: date.addingTimeInterval(-60),
      deliveryState: .delivered)
    do {
      let direct = try Conversation(
        id: directMessage.conversationID, kind: .direct, name: ava.displayName,
        memberIDs: [currentUser.id, ava.id], unreadCount: 1,
        lastMessage: directMessage, updatedAt: directMessage.sentAt)
      let group = try Conversation(
        id: groupMessage.conversationID, kind: .group, name: "Design Team",
        memberIDs: [currentUser.id, ava.id, noah.id], unreadCount: 2,
        lastMessage: groupMessage, updatedAt: groupMessage.sentAt)
      return MockSeed(
        users: [currentUser, ava, noah] + extras, conversations: [direct, group],
        messages: [directMessage, groupMessage])
    } catch {
      preconditionFailure("Invalid built-in conversation fixture: \(error)")
    }
  }
}
