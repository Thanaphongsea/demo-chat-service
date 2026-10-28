import SwiftUI

nonisolated enum ChatRoomFixture { case populated, empty, loading, failed, failSendOnce }

actor ChatRoomFixtureClient: ChatClient {
  private let fixture: ChatRoomFixture
  private let base: MockChatClient
  private var didFailSend = false

  init(
    fixture: ChatRoomFixture, seed: MockSeed = .standard,
    scheduler: any DemoScheduler = ImmediateDemoScheduler()
  ) {
    self.fixture = fixture
    base = MockChatClient(seed: seed, scheduler: scheduler)
  }

  func messages(in conversationID: ConversationID) async throws -> [Message] {
    switch fixture {
    case .empty: return []
    case .loading: try await Task.sleep(for: .seconds(3600))
    case .failed: throw ChatError.conversationNotFound
    case .populated, .failSendOnce: break
    }
    return try await base.messages(in: conversationID)
  }

  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    if fixture == .failSendOnce && !didFailSend {
      didFailSend = true
      throw ChatError.conversationNotFound
    }
    return try await base.send(text: text, to: conversationID)
  }

  func events() async -> AsyncStream<ChatEvent> { await base.events() }
  func listConversations() async throws -> [Conversation] { try await base.listConversations() }
  func listUsers() async throws -> [User] { try await base.listUsers() }
  func createDirect(with userID: UserID) async throws -> Conversation {
    try await base.createDirect(with: userID)
  }
  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    try await base.createGroup(name: name, members: members)
  }
}

struct ChatRoomPreview: View {
  @State private var store: ChatRoomStore
  private let kind: ConversationKind

  static let outgoing = Message(
    id: MessageID("preview-outgoing"), conversationID: ConversationID("conversation-ava"),
    senderID: MockSeed.currentUser.id,
    text:
      "Absolutely! I’ll bring the notes. This longer message wraps naturally as text size changes.",
    sentAt: MockSeed.date.addingTimeInterval(1), deliveryState: .delivered)

  init(kind: ConversationKind = .direct, fixture: ChatRoomFixture = .populated) {
    self.kind = kind
    let seed = MockSeed.standard
    let id = ConversationID(kind == .direct ? "conversation-ava" : "conversation-team")
    let outgoing = Message(
      id: Self.outgoing.id, conversationID: id, senderID: Self.outgoing.senderID,
      text: Self.outgoing.text, sentAt: Self.outgoing.sentAt, deliveryState: .delivered)
    let previewSeed = MockSeed(
      users: seed.users, conversations: seed.conversations, messages: seed.messages + [outgoing])
    _store = State(
      initialValue: ChatRoomStore(
        conversationID: id, currentUserID: MockSeed.currentUser.id,
        client: ChatRoomFixtureClient(fixture: fixture, seed: previewSeed), now: { MockSeed.date }))
  }

  var body: some View {
    NavigationStack {
      ChatRoomView(
        store: store, title: kind == .direct ? "Ava Chen" : "Design Team", kind: kind, video: {})
    }
  }
}
