import SwiftUI

nonisolated enum ConversationListFixture {
  case populated, empty, loading, failed, failOnce
}

/// The same deterministic scenarios drive previews and launch-argument UI fixtures.
actor ConversationFixtureClient: ChatClient {
  private let fixture: ConversationListFixture
  private let base: MockChatClient
  private var didFail = false

  init(fixture: ConversationListFixture) {
    self.fixture = fixture
    base = MockChatClient(
      seed: fixture == .empty ? MockSeed(users: [], conversations: [], messages: []) : .standard)
  }

  func listConversations() async throws -> [Conversation] {
    if fixture == .loading { try await Task.sleep(for: .seconds(3600)) }
    if fixture == .failed || (fixture == .failOnce && !didFail) {
      didFail = true
      throw ChatError.conversationNotFound
    }
    return try await base.listConversations()
  }

  func events() async -> AsyncStream<ChatEvent> { await base.events() }
  func listUsers() async throws -> [User] { try await base.listUsers() }
  func messages(in conversationID: ConversationID) async throws -> [Message] {
    try await base.messages(in: conversationID)
  }
  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    try await base.send(text: text, to: conversationID)
  }
  func createDirect(with userID: UserID) async throws -> Conversation {
    try await base.createDirect(with: userID)
  }
  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    try await base.createGroup(name: name, members: members)
  }
}

struct ConversationListPreview: View {
  @State private var store: ConversationListStore

  init(fixture: ConversationListFixture) {
    _store = State(
      initialValue: ConversationListStore(client: ConversationFixtureClient(fixture: fixture)))
  }

  var body: some View {
    NavigationStack { ConversationListView(store: store) }
      .onDisappear { store.reset() }
  }
}
