import Foundation
import Testing

@testable import ChatCall

@MainActor
struct ConversationListStoreTests {
  @Test("A pending load shows loading, then newest rooms with deterministic ties")
  func loadingAndStableSorting() async throws {
    let rooms = try tiedRooms()
    let client = ControlledListClient(rooms: rooms, deferred: true)
    let store = ConversationListStore(client: client)
    let request = Task { await store.load() }
    defer { request.cancel() }
    try #require(await waitUntil { await client.pendingLoads == 1 })
    #expect(store.state == .loading)
    await client.completeLoad()
    try #require(await waitUntil { store.state == .loaded })
    #expect(store.visibleConversations.map(\.id.rawValue) == ["b-new", "a-tie", "z-tie"])
    #expect(store.totalUnreadCount == 3)
  }

  @Test("An empty repository is distinct from an unmatched search")
  func emptyAndSearch() async {
    let empty = ConversationListStore(
      client: MockChatClient(seed: MockSeed(users: [], conversations: [], messages: [])))
    await empty.load()
    #expect(empty.state == .empty)
    let store = ConversationListStore(client: MockChatClient())
    await store.load()
    store.searchText = "  AVA  "
    #expect(store.visibleConversations.map(\.id.rawValue) == ["conversation-ava"])
    store.searchText = "CALL"
    #expect(store.visibleConversations.map(\.id.rawValue) == ["conversation-team"])
    store.searchText = "missing"
    #expect(store.visibleConversations.isEmpty)
    #expect(store.state == .loaded)
    store.searchText = " \n "
    #expect(store.visibleConversations.count == 2)
  }

  @Test("A failed load can retry and replace its error with rooms")
  func failureAndRetry() async {
    let store = ConversationListStore(
      client: ControlledListClient(rooms: MockSeed.standard.conversations, failOnce: true))
    await store.load()
    #expect(store.state == .failed("Unable to load chats. Please try again."))
    await store.load()
    #expect(store.state == .loaded)
    #expect(store.visibleConversations.count == 2)
  }

  @Test("Updates replace unread counts, reorder rooms, and never duplicate an existing room")
  func updatesUnreadAndOrdering() async throws {
    let client = ControlledListClient(rooms: MockSeed.standard.conversations)
    let store = ConversationListStore(client: client)
    store.start()
    defer { store.reset() }
    try #require(await waitUntil { store.state == .loaded })
    let update = try Conversation(
      id: ConversationID("conversation-team"), kind: .group, name: "Design Team",
      memberIDs: [UserID("user-me"), UserID("user-ava"), UserID("user-noah")],
      unreadCount: 7, updatedAt: MockSeed.date.addingTimeInterval(10))
    await client.emit(.conversationUpdated(update))
    try #require(await waitUntil { store.totalUnreadCount == 8 })
    #expect(
      store.visibleConversations.map(\.id.rawValue) == [
        "conversation-team", "conversation-ava"
      ])
    await client.emit(.conversationUpdated(update))
    #expect(await waitUntil { store.visibleConversations.count == 2 })
  }

  @Test("An update buffered during the initial snapshot is applied after the snapshot")
  func bufferedEventDuringLoad() async throws {
    let client = ControlledListClient(rooms: [], deferred: true)
    let store = ConversationListStore(client: client)
    store.start()
    defer { store.reset() }
    try #require(await waitUntil { await client.pendingLoads == 1 })
    await client.emit(.conversationUpdated(MockSeed.standard.conversations[0]))
    await client.completeLoad()
    try #require(await waitUntil { store.state == .loaded })
    #expect(store.visibleConversations.map(\.id.rawValue) == ["conversation-ava"])
  }

  @Test("Reset cancels the event stream and rejects buffered events and a late snapshot")
  func resetRejectsStaleWork() async throws {
    let client = ControlledListClient(rooms: MockSeed.standard.conversations, deferred: true)
    let store = ConversationListStore(client: client)
    store.start()
    try #require(await waitUntil { await client.pendingLoads == 1 })
    store.searchText = "private query"
    await client.emit(.conversationUpdated(MockSeed.standard.conversations[0]))
    store.reset()
    await client.completeLoad()
    try #require(await waitUntil { await client.terminatedStreams == 1 })
    #expect(store.visibleConversations.isEmpty)
    #expect(store.searchText.isEmpty)
    #expect(store.totalUnreadCount == 0)
    #expect(store.state == .loading)
    store.start()
    try #require(await waitUntil { await client.pendingLoads == 1 })
    await client.completeLoad()
    try #require(await waitUntil { store.state == .loaded })
    #expect(store.visibleConversations.count == 2)
    store.reset()
  }

  @Test("Logout replaces every tab path and clears list data before Login")
  func logoutResetsAllRouters() async {
    let auth = AuthStore(client: MockAuthClient())
    let router = AppRouter(chatClient: MockChatClient())
    auth.resetAuthenticatedState = { router.reset() }
    auth.username = "alex"
    auth.password = "123456"
    await auth.signIn()
    await router.conversations.load()
    let oldChats = router.chats
    let oldCalls = router.calls
    let oldProfile = router.profile
    router.chats.routes = [.room(ConversationID("conversation-ava"))]
    router.calls.routes = [.call(CallID("call-1"))]
    router.profile.routes = [.profile]
    router.selectedTab = .profile
    await auth.signOut()
    #expect(auth.state == .unauthenticated)
    #expect(router.chats !== oldChats)
    #expect(router.calls !== oldCalls)
    #expect(router.profile !== oldProfile)
    #expect(
      router.chats.routes.isEmpty && router.calls.routes.isEmpty && router.profile.routes.isEmpty)
    #expect(router.selectedTab == .chats)
    #expect(router.conversations.visibleConversations.isEmpty)
  }

  private func tiedRooms() throws -> [Conversation] {
    try [("z-tie", 0.0), ("b-new", 1.0), ("a-tie", 0.0)].map { id, offset in
      try Conversation(
        id: ConversationID(id), kind: .direct, name: id,
        memberIDs: [UserID("user-me"), UserID("user-ava")], unreadCount: 1,
        updatedAt: MockSeed.date.addingTimeInterval(offset))
    }
  }
}

private actor ControlledListClient: ChatClient {
  let rooms: [Conversation]
  let deferred: Bool
  var failOnce: Bool
  var pendingLoads: Int { loads.count }
  var terminatedStreams = 0
  private var loads: [CheckedContinuation<[Conversation], any Error>] = []
  private var continuation: AsyncStream<ChatEvent>.Continuation?
  private let base = MockChatClient()

  init(rooms: [Conversation], deferred: Bool = false, failOnce: Bool = false) {
    self.rooms = rooms
    self.deferred = deferred
    self.failOnce = failOnce
  }

  func listConversations() async throws -> [Conversation] {
    if failOnce {
      failOnce = false
      throw ChatError.conversationNotFound
    }
    if deferred { return try await withCheckedThrowingContinuation { loads.append($0) } }
    return rooms
  }

  func completeLoad() { loads.removeFirst().resume(returning: rooms) }
  func emit(_ event: ChatEvent) { continuation?.yield(event) }

  func events() async -> AsyncStream<ChatEvent> {
    let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
    self.continuation = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.terminated() } }
    return stream
  }

  private func terminated() { terminatedStreams += 1 }
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
