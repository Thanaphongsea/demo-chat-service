import Foundation
import Testing

@testable import ChatCall

@MainActor
struct NewConversationStoreTests {
  @Test("Finishing compose dismisses its sheet, inserts the room, and uses the typed chat route")
  func typedRouting() async throws {
    let router = AppRouter(chatClient: MockChatClient())
    router.presentComposer(currentUserID: UserID("user-me"))
    guard case .newConversation(let store) = router.presentedSheet else {
      Issue.record("Compose must present a typed sheet")
      return
    }
    await store.load()
    store.toggle(MockSeed.standard.users[2])
    await store.proceed()
    let room = try #require(store.createdConversation)
    router.finishCompose(room, from: store)
    #expect(router.presentedSheet == nil)
    #expect(router.chats.routes == [.room(room.id)])
    #expect(router.conversations.conversations.first?.name == "Noah Williams")
  }

  @Test("Reset clears compose state and rejects a dismissed sheet's late route")
  func resetRejectsOldRoute() async {
    let router = AppRouter(chatClient: MockChatClient())
    router.presentComposer(currentUserID: UserID("user-me"))
    guard case .newConversation(let store) = router.presentedSheet else {
      Issue.record("Compose must present a typed sheet")
      return
    }
    await store.load()
    store.toggle(MockSeed.standard.users[1])
    router.reset()
    #expect(router.presentedSheet == nil)
    #expect(store.selectedUsers.isEmpty)
    router.finishCompose(MockSeed.standard.conversations[0], from: store)
    #expect(router.chats.routes.isEmpty)
    #expect(router.conversations.conversations.isEmpty)
  }

  @Test("Search trims whitespace and matches names without case sensitivity")
  func search() async {
    let store = makeStore()
    await store.load()
    store.searchText = "  AVA  "
    #expect(store.visibleUsers.map(\.id.rawValue) == ["user-ava"])
    store.searchText = "missing"
    #expect(store.visibleUsers.isEmpty)
    store.searchText = " \n "
    #expect(store.visibleUsers.count == 17)
    #expect(store.state == .loaded)
  }

  @Test("The picker excludes self, deduplicates IDs, and only toggles known users")
  func rosterAndSelection() async {
    let ava = MockSeed.standard.users[1]
    let store = makeStore(client: ComposeClient(users: [MockSeed.currentUser, ava, ava]))
    await store.load()
    #expect(store.visibleUsers.map(\.id.rawValue) == ["user-ava"])
    store.toggle(MockSeed.currentUser)
    store.toggle(MockSeed.standard.users[2])
    #expect(store.selectedUsers.isEmpty)
    store.toggle(ava)
    #expect(store.selectedUsers.map(\.id.rawValue) == ["user-ava"])
    #expect(store.canContinue)
    store.toggle(ava)
    #expect(store.selectedUsers.isEmpty)
    #expect(!store.canContinue)
  }

  @Test("No selection cannot create or advance")
  func noSelection() async {
    let store = makeStore()
    await store.load()
    await store.proceed()
    #expect(store.step == .members)
    #expect(store.createdConversation == nil)
  }

  @Test("One selected user opens the existing direct room without duplicating it")
  func directReuse() async throws {
    let client = MockChatClient()
    let store = makeStore(client: client)
    await store.load()
    store.toggle(MockSeed.standard.users[1])
    await store.proceed()
    #expect(store.createdConversation?.id.rawValue == "conversation-ava")
    #expect(store.createdConversation?.kind == .direct)
    #expect(try await client.listConversations().count == 2)
  }

  @Test("One selected new contact creates a direct room with self and that contact")
  func newDirect() async {
    let store = makeStore()
    await store.load()
    store.toggle(MockSeed.standard.users[2])
    await store.proceed()
    #expect(store.createdConversation?.name == "Noah Williams")
    #expect(store.createdConversation?.memberIDs.map(\.rawValue) == ["user-me", "user-noah"])
  }

  @Test("Two selected people advance to group details and trim the new group name")
  func groupCreation() async {
    let store = await groupStore()
    #expect(store.step == .groupDetails)
    #expect(store.createdConversation == nil)
    store.groupName = "  Weekend crew \n"
    #expect(store.canCreateGroup)
    await store.createGroup()
    #expect(store.createdConversation?.kind == .group)
    #expect(store.createdConversation?.name == "Weekend crew")
    #expect(
      store.createdConversation?.memberIDs.map(\.rawValue) == [
        "user-me", "user-ava", "user-noah"
      ])
  }

  @Test("Blank names and fewer than two other members cannot create a group")
  func groupValidation() async {
    let store = await groupStore()
    store.groupName = " \n "
    #expect(!store.canCreateGroup)
    await store.createGroup()
    #expect(store.createdConversation == nil)
    #expect(store.failure == .chat(.groupNameRequired))
    store.groupName = "Team"
    store.toggle(MockSeed.standard.users[2])
    #expect(!store.canCreateGroup)
    await store.createGroup()
    #expect(store.createdConversation == nil)
    #expect(store.failure == .chat(.invalidMembers))
  }

  @Test("Load and create preserve typed failures and allow retry")
  func failuresAndRetry() async {
    let client = ComposeClient(failLoadOnce: true, failCreateOnce: true)
    let store = makeStore(client: client)
    await store.load()
    #expect(store.state == .failed(.chat(.userNotFound)))
    await store.load()
    #expect(store.state == .loaded)
    store.toggle(MockSeed.standard.users[1])
    await store.proceed()
    #expect(store.failure == .chat(.invalidMembers))
    #expect(store.createdConversation == nil)
    #expect(store.canContinue)
    await store.proceed()
    #expect(store.createdConversation?.id.rawValue == "conversation-ava")
    #expect(store.failure == nil)
  }

  @Test("A pending create suppresses repeat submits and freezes the selected roster")
  func duplicateSubmit() async throws {
    let client = ComposeClient(deferCreate: true)
    let store = makeStore(client: client)
    await store.load()
    store.toggle(MockSeed.standard.users[1])
    var finished = false
    let request = Task {
      await store.proceed()
      finished = true
    }
    defer { request.cancel() }
    try #require(await waitUntil { await client.pendingCreates == 1 })
    #expect(store.isCreating)
    #expect(!store.canContinue)
    store.toggle(MockSeed.standard.users[2])
    await store.proceed()
    #expect(store.selectedUsers.map(\.id.rawValue) == ["user-ava"])
    await client.completeCreate()
    try #require(await waitUntil { finished })
    #expect(store.createdConversation?.id.rawValue == "conversation-ava")
    #expect(await client.createCount == 1)
  }

  @Test("Cancellation discards a late create result and clears private compose state")
  func cancellation() async throws {
    let client = ComposeClient(deferCreate: true)
    let store = makeStore(client: client)
    await store.load()
    store.toggle(MockSeed.standard.users[1])
    store.searchText = "private"
    store.groupName = "private"
    var finished = false
    let request = Task {
      await store.proceed()
      finished = true
    }
    defer { request.cancel() }
    try #require(await waitUntil { await client.pendingCreates == 1 })
    store.cancel()
    await client.completeCreate()
    try #require(await waitUntil { finished })
    #expect(store.createdConversation == nil)
    #expect(store.selectedUsers.isEmpty)
    #expect(store.searchText.isEmpty && store.groupName.isEmpty)
    #expect(!store.isCreating)
    #expect(store.failure == nil)
  }

  @Test("A cancelled caller ignores a late user roster")
  func cancelledLoad() async throws {
    let client = ComposeClient(deferLoad: true)
    let store = makeStore(client: client)
    var finished = false
    let request = Task {
      await store.load()
      finished = true
    }
    defer { request.cancel() }
    try #require(await waitUntil { await client.pendingLoads == 1 })
    request.cancel()
    await client.completeLoad()
    try #require(await waitUntil { finished })
    #expect(store.visibleUsers.isEmpty)
    #expect(store.failure == nil)
  }

  private func makeStore(client: any ChatClient = MockChatClient()) -> NewConversationStore {
    NewConversationStore(client: client, currentUserID: UserID("user-me"))
  }

  private func groupStore() async -> NewConversationStore {
    let store = makeStore()
    await store.load()
    store.toggle(MockSeed.standard.users[1])
    store.toggle(MockSeed.standard.users[2])
    await store.proceed()
    return store
  }
}

private actor ComposeClient: ChatClient {
  let users: [User]
  let deferCreate: Bool
  let deferLoad: Bool
  var failLoadOnce: Bool
  var failCreateOnce: Bool
  var createCount = 0
  var pendingCreates: Int { creates.count }
  var pendingLoads: Int { loads.count }
  private var creates: [CheckedContinuation<Void, Never>] = []
  private var loads: [CheckedContinuation<Void, Never>] = []
  private let base = MockChatClient()

  init(
    users: [User] = MockSeed.standard.users, deferCreate: Bool = false,
    deferLoad: Bool = false, failLoadOnce: Bool = false, failCreateOnce: Bool = false
  ) {
    self.users = users
    self.deferCreate = deferCreate
    self.deferLoad = deferLoad
    self.failLoadOnce = failLoadOnce
    self.failCreateOnce = failCreateOnce
  }

  func listUsers() async throws -> [User] {
    if failLoadOnce {
      failLoadOnce = false
      throw ChatError.userNotFound
    }
    if deferLoad { await withCheckedContinuation { loads.append($0) } }
    return users
  }

  func completeLoad() { loads.removeFirst().resume() }
  func completeCreate() { creates.removeFirst().resume() }
  func createDirect(with userID: UserID) async throws -> Conversation {
    createCount += 1
    if failCreateOnce {
      failCreateOnce = false
      throw ChatError.invalidMembers
    }
    if deferCreate { await withCheckedContinuation { creates.append($0) } }
    return try await base.createDirect(with: userID)
  }
  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    try await base.createGroup(name: name, members: members)
  }
  func listConversations() async throws -> [Conversation] { try await base.listConversations() }
  func messages(in conversationID: ConversationID) async throws -> [Message] {
    try await base.messages(in: conversationID)
  }
  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    try await base.send(text: text, to: conversationID)
  }
  func events() async -> AsyncStream<ChatEvent> { await base.events() }
}
