nonisolated protocol ChatClient: Sendable {
  func listConversations() async throws -> [Conversation]
  func listUsers() async throws -> [User]
  func messages(in conversationID: ConversationID) async throws -> [Message]
  func send(text: String, to conversationID: ConversationID) async throws -> Message
  func createDirect(with userID: UserID) async throws -> Conversation
  func createGroup(name: String, members: [UserID]) async throws -> Conversation
  func events() async -> AsyncStream<ChatEvent>
}
