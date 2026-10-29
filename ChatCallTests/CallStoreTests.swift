import Testing

@testable import ChatCall

@MainActor
struct CallStoreTests {
  @Test("A client that completes after logout cannot restore private history on the next session")
  func lateClientCompletion() async throws {
    let client = SuspendedStartCallClient()
    let store = CallStore(client: client, chatClient: MockChatClient())
    let start = Task { await store.startVideo(in: ConversationID("conversation-ava")) }
    try #require(await waitUntil { await client.isWaiting })
    store.reset()
    await client.resume()
    await start.value
    await store.start()
    #expect(store.history.isEmpty)
    #expect(store.call == nil)
    #expect(!store.isPresented)
    store.reset()
  }

  @Test("Starting observation loads history and presents incoming client events without a command")
  func observesClient() async throws {
    let client = MockCallClient()
    _ = try await client.demoMissedCall(kind: .direct)
    let store = CallStore(client: client, chatClient: MockChatClient())
    await store.start()
    #expect(store.history.map(\.state) == [.missed])
    #expect(!store.isPresented)
    _ = try await client.demoIncomingCall(kind: .group)
    try #require(await waitUntil { store.call?.state == .incoming })
    #expect(store.isPresented)
    await store.decline()
    store.reset()
    await store.start()
    #expect(store.history.isEmpty)
    #expect(!store.isPresented)
    store.reset()
  }

  // A suspended roster load must never create a call after logout.
  @Test("Logout cancels an in-flight start before it reaches the call client")
  func logoutDuringStart() async throws {
    let chat = SuspendedCallRosterClient()
    let client = MockCallClient()
    let store = CallStore(client: client, chatClient: chat)
    let start = Task { await store.startVideo(in: ConversationID("conversation-ava")) }
    try #require(await waitUntil { await chat.isWaiting })
    store.reset()
    await chat.resume()
    await start.value
    #expect(await client.currentCall == nil)
    #expect(await client.history().isEmpty)
    #expect(store.call == nil)
    #expect(!store.isBusy)
  }

  @Test("Cancelling the caller releases busy state and permits another call")
  func cancelledStartCanRetry() async throws {
    let chat = SuspendedCallRosterClient()
    let store = CallStore(client: MockCallClient(), chatClient: chat)
    let start = Task { await store.startVideo(in: ConversationID("conversation-ava")) }
    try #require(await waitUntil { await chat.isWaiting })
    start.cancel()
    await chat.resume()
    await start.value
    #expect(!store.isBusy)
    #expect(store.errorMessage == nil)
    await store.incoming(kind: .direct)
    #expect(store.call?.state == .incoming)
    await store.decline()
    store.reset()
  }

  @Test("Outgoing direct and group use fresh complete conversation membership")
  func outgoing() async throws {
    let scheduler = ManualDemoScheduler()
    let chat = MockChatClient()
    let store = CallStore(client: MockCallClient(scheduler: scheduler), chatClient: chat)
    await store.startVideo(in: ConversationID("conversation-ava"))
    #expect(store.call?.state == .ringing)
    #expect(store.call?.participants.map(\.id.rawValue) == ["user-me", "user-ava"])
    try #require(await scheduler.waitForPendingSleep())
    await scheduler.advance()
    try #require(await waitUntil { store.call?.state == .active })
    await store.end()
    #expect(store.call?.state == .ended)
    store.dismiss()
    let group = try await chat.createGroup(
      name: "All members",
      members: [UserID("user-ava"), UserID("user-noah"), UserID("user-1"), UserID("user-2")])
    await store.startVideo(in: group.id)
    #expect(store.call?.kind == .group)
    #expect(
      store.call?.participants.map(\.id.rawValue) == [
        "user-me", "user-ava", "user-noah", "user-1", "user-2"
      ])
    #expect(store.isPresented)
    await store.end()
    store.reset()
  }

  @Test("Incoming answer, media controls, reconnect, end, decline and missed history")
  func incomingControlsHistory() async throws {
    let scheduler = ManualDemoScheduler()
    let store = CallStore(
      client: MockCallClient(scheduler: scheduler), chatClient: MockChatClient())
    await store.incoming(kind: .direct)
    #expect(store.call?.state == .incoming)
    await store.answer()
    #expect(store.call?.state == .active)
    await store.toggleMicrophone()
    await store.toggleCamera()
    await store.toggleSpeaker()
    await store.flipCamera()
    #expect(store.call?.microphoneEnabled == false)
    #expect(store.call?.cameraEnabled == false)
    #expect(store.page.tiles.first?.isVideoEnabled == false)
    #expect(store.call?.speakerEnabled == false)
    #expect(store.call?.cameraPosition == .back)
    await store.reconnect()
    #expect(store.call?.state == .reconnecting)
    try #require(await scheduler.waitForPendingSleep())
    await scheduler.advance()
    try #require(await waitUntil { store.call?.state == .active })
    await store.end()
    store.dismiss()
    await store.incoming(kind: .group)
    #expect(store.call?.kind == .group)
    await store.decline()
    store.dismiss()
    await store.missed(kind: .direct)
    #expect(store.history.map(\.state) == [.missed, .declined, .ended])
    #expect(!store.isPresented)
    store.reset()
  }

  // Replaying terminal events must not duplicate history or resurrect dismissed calls.
  @Test("Duplicates, backwards transitions, foreign active calls and terminal controls are ignored")
  func invalidEvents() async throws {
    let store = CallStore(client: MockCallClient(), chatClient: MockChatClient())
    await store.incoming(kind: .direct)
    let incoming = try #require(store.call)
    await store.incoming(kind: .group)
    #expect(store.call?.id == incoming.id)
    await store.answer()
    let foreign = CallSnapshot(
      id: CallID("foreign"), conversationID: ConversationID("conversation-team"), kind: .group,
      direction: .incoming, state: .incoming,
      participants: Array(MockSeed.standard.users.prefix(3)),
      startedAt: MockSeed.date, microphoneEnabled: true, cameraEnabled: true,
      speakerEnabled: true, cameraPosition: .front)
    store.receive(.callUpdated(foreign))
    #expect(store.call?.id == incoming.id)
    store.receive(.callUpdated(incoming))
    #expect(store.call?.state == .active)
    await store.decline()
    #expect(store.call?.state == .active)
    await store.end()
    let ended = try #require(store.call)
    store.receive(.callUpdated(ended))
    store.receive(.callUpdated(incoming))
    await store.toggleCamera()
    #expect(store.call?.state == .ended)
    #expect(store.history.count == 1)
    store.dismiss()
    store.receive(.callUpdated(ended))
    #expect(!store.isPresented)
    store.reset()
  }

  @Test("Capacity rejection leaves no presented call; exactly sixteen can start")
  func capacity() async throws {
    let chat = MockChatClient()
    let store = CallStore(client: MockCallClient(), chatClient: chat)
    let oversized = try await chat.createGroup(
      name: "Too many", members: Array(MockSeed.standard.users.dropFirst().prefix(16)).map(\.id))
    await store.startVideo(in: oversized.id)
    #expect(store.call == nil)
    #expect(!store.isPresented)
    #expect(store.errorMessage != nil)
    let boundary = try await chat.createGroup(
      name: "Sixteen", members: Array(MockSeed.standard.users.dropFirst().prefix(15)).map(\.id))
    await store.startVideo(in: boundary.id)
    #expect(store.call?.participants.count == 16)
    #expect(store.page.pageCount == 5)
    await store.end()
    store.reset()
  }

  @Test("Logout resets presentation and cancels delayed activation; a later session can call")
  func logout() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockCallClient(scheduler: scheduler)
    let router = AppRouter(chatClient: MockChatClient(), callClient: client)
    await router.callStore.startVideo(in: ConversationID("conversation-ava"))
    try #require(await scheduler.waitForPendingSleep())
    router.reset()
    try #require(await waitUntil { await client.currentCall?.state == .ended })
    await scheduler.advance(by: .seconds(10))
    #expect(router.callStore.call == nil)
    #expect(router.callStore.history.isEmpty)
    #expect(!router.callStore.isPresented)
    await router.callStore.incoming(kind: .group)
    #expect(router.callStore.call?.state == .incoming)
    await router.callStore.decline()
    router.reset()
  }
}

private actor SuspendedCallRosterClient: ChatClient {
  private var continuation: CheckedContinuation<[Conversation], Never>?
  private let base = MockChatClient()
  var isWaiting: Bool { continuation != nil }
  func listConversations() async throws -> [Conversation] {
    await withCheckedContinuation { continuation = $0 }
  }
  func resume() {
    continuation?.resume(returning: MockSeed.standard.conversations)
    continuation = nil
  }
  func listUsers() async throws -> [User] { try await base.listUsers() }
  func messages(in id: ConversationID) async throws -> [Message] { try await base.messages(in: id) }
  func send(text: String, to id: ConversationID) async throws -> Message {
    try await base.send(text: text, to: id)
  }
  func createDirect(with id: UserID) async throws -> Conversation {
    try await base.createDirect(with: id)
  }
  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    try await base.createGroup(name: name, members: members)
  }
  func events() async -> AsyncStream<ChatEvent> { await base.events() }
}

// This adapter intentionally ignores cancellation after entering the external start operation.
private actor SuspendedStartCallClient: CallClient {
  private let base = MockCallClient()
  private var continuation: CheckedContinuation<Void, Never>?
  var isWaiting: Bool { continuation != nil }
  var currentCall: CallSnapshot? { get async { await base.currentCall } }
  func history() async -> [CallSnapshot] { await base.history() }
  func startVideoCall(in conversation: Conversation) async throws -> CallSnapshot {
    await withCheckedContinuation { continuation = $0 }
    return try await base.startVideoCall(in: conversation)
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
  func answer(callID: CallID) async throws -> CallSnapshot { try await base.answer(callID: callID) }
  func decline(callID: CallID) async throws -> CallSnapshot {
    try await base.decline(callID: callID)
  }
  func end(callID: CallID) async throws -> CallSnapshot { try await base.end(callID: callID) }
  func join(callID: CallID) async throws -> CallSnapshot { try await base.join(callID: callID) }
  func endForEveryone(callID: CallID) async throws -> CallSnapshot {
    try await base.endForEveryone(callID: callID)
  }
  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    try await base.setMicrophoneEnabled(enabled, callID: callID)
  }
  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    try await base.setCameraEnabled(enabled, callID: callID)
  }
  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    try await base.setSpeakerEnabled(enabled, callID: callID)
  }
  func flipCamera(callID: CallID) async throws -> CallSnapshot {
    try await base.flipCamera(callID: callID)
  }
  func demoIncomingCall(kind: CallKind) async throws -> CallSnapshot {
    try await base.demoIncomingCall(kind: kind)
  }
  func demoMissedCall(kind: CallKind) async throws -> CallSnapshot {
    try await base.demoMissedCall(kind: kind)
  }
  func demoReconnect(callID: CallID) async throws -> CallSnapshot {
    try await base.demoReconnect(callID: callID)
  }
  func events() async -> AsyncStream<CallEvent> { await base.events() }
}
