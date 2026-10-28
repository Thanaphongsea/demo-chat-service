import Foundation
import Testing

@testable import ChatCall

@MainActor
struct ChatRoomStoreTests {
  private let room = ConversationID("conversation-ava")

  // Removing snapshot loading would leave the room in its loading state.
  @Test("Loads only the requested conversation and exposes the latest scroll target")
  func initialLoad() async throws {
    let store = makeStore(client: MockChatClient())
    #expect(store.state == .loading)
    await store.load()
    #expect(store.state == .loaded)
    #expect(store.orderedMessages.map(\.message.text) == ["Ready to catch up?"])
    #expect(store.scrollTargetID == MessageID("message-ava-1"))
  }

  // Treating an empty snapshot as loading would hide the composer indefinitely.
  @Test("An empty snapshot finishes loading")
  func emptyLoad() async {
    let store = makeStore(client: ControlledRoomClient(messages: []))
    await store.load()
    #expect(store.state == .empty)
    #expect(store.scrollTargetID == nil)
  }

  @Test("A load failure can retry successfully")
  func loadRetry() async {
    let store = makeStore(client: ControlledRoomClient(failLoadOnce: true))
    await store.load()
    #expect(store.state == .failed("Unable to load messages. Please try again."))
    await store.load()
    #expect(store.state == .loaded)
  }

  // Removing trim validation would insert a blank bubble and clear the draft.
  @Test("Whitespace cannot send; a valid draft is trimmed and inserted before acknowledgment")
  func optimisticTrimmedSend() async throws {
    let client = ControlledRoomClient(deferSend: true)
    let store = makeStore(client: client)
    await store.load()
    store.draft = " \n\t "
    #expect(!store.canSend)
    store.send()
    #expect(store.orderedMessages.count == 1)
    #expect(store.draft == " \n\t ")
    store.draft = "  Hello Ava \n"
    #expect(store.canSend)
    store.send()
    let optimistic = try #require(store.orderedMessages.last)
    #expect(optimistic.message.text == "Hello Ava")
    #expect(optimistic.status == .sending)
    #expect(store.draft.isEmpty)
    try #require(await waitUntil { await client.pendingSends == 1 })
    await client.finishSend()
    try #require(
      await waitUntil { store.orderedMessages.last?.message.id == MessageID("server-1") })
    #expect(store.orderedMessages.last?.id == optimistic.id)
    #expect(store.orderedMessages.count == 2)
    store.cancel()
  }

  @Test(
    "Shared client delivery events progress sending to sent to delivered and update list previews")
  func deliveryAndPreview() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockChatClient(scheduler: scheduler)
    let list = ConversationListStore(client: client)
    let store = makeStore(client: client)
    list.start()
    store.start()
    try #require(await waitUntil { store.state == .loaded && list.state == .loaded })
    store.draft = "A new preview"
    store.send()
    try #require(await waitUntil { await scheduler.pendingCount == 1 })
    try #require(
      await waitUntil { store.orderedMessages.last?.message.id.rawValue == "message-created-1" })
    #expect(store.orderedMessages.last?.status == .sending)
    await scheduler.advance()
    try #require(await waitUntil { store.orderedMessages.last?.status == .sent })
    try #require(await waitUntil { await scheduler.pendingCount == 1 })
    await scheduler.advance()
    try #require(await waitUntil { store.orderedMessages.last?.status == .delivered })
    try #require(
      await waitUntil { list.visibleConversations.first?.lastMessage?.text == "A new preview" })
    #expect(store.orderedMessages.count == 2)
    store.cancel()
    list.reset()
  }

  @Test("A failed send retries the same row without clearing a newer draft")
  func failedSendRetry() async throws {
    let client = ControlledRoomClient(failSendOnce: true)
    let store = makeStore(client: client)
    await store.load()
    store.draft = "Try again"
    store.send()
    let id = try #require(store.scrollTargetID)
    try #require(await waitUntil { store.orderedMessages.last?.status == .failed })
    store.draft = "Keep writing"
    store.retry(id)
    try #require(await waitUntil { store.orderedMessages.last?.status == .sent })
    #expect(store.orderedMessages.count == 2)
    #expect(store.orderedMessages.last?.id == id)
    #expect(store.orderedMessages.last?.message.text == "Try again")
    #expect(store.draft == "Keep writing")
    store.retry(id)
    #expect(store.orderedMessages.last?.status == .sent)
    store.cancel()
  }

  // Missing the room guard or replacing rows on every event would corrupt this timeline.
  @Test("Duplicate inserts and out-of-order delivery are idempotent; other rooms are ignored")
  func scopedEvents() async throws {
    let client = ControlledRoomClient()
    let store = makeStore(client: client)
    store.start()
    try #require(await waitUntil { store.state == .loaded })
    let incoming = message("incoming", offset: 2)
    await client.emit(
      .deliveryChanged(messageID: incoming.id, conversationID: room, state: .delivered))
    await client.emit(.messageInserted(incoming))
    await client.emit(.messageInserted(incoming))
    await client.emit(.deliveryChanged(messageID: incoming.id, conversationID: room, state: .sent))
    let wrong = message("wrong", conversationID: ConversationID("conversation-team"))
    await client.emit(.messageInserted(wrong))
    await client.emit(
      .deliveryChanged(
        messageID: incoming.id, conversationID: wrong.conversationID, state: .sending))
    let scoped = message("scoped-delivery", offset: 3)
    await client.emit(.messageInserted(scoped))
    await client.emit(
      .deliveryChanged(
        messageID: scoped.id, conversationID: wrong.conversationID, state: .delivered))
    // A final same-room insert is a processing barrier for the ordered stream.
    await client.emit(.messageInserted(message("barrier", offset: 4)))
    try #require(await waitUntil { store.orderedMessages.count == 4 })
    #expect(
      store.orderedMessages.map(\.message.id.rawValue) == [
        "message-ava-1", "incoming", "scoped-delivery", "barrier"
      ])
    #expect(store.orderedMessages[1].status == .delivered)
    #expect(store.orderedMessages[2].status == .sent)
    store.cancel()
  }

  @Test(
    "Equal timestamps sort by ID, duplicate snapshots collapse, and local days group chronologically"
  )
  func chronologicalSections() async {
    let client = ControlledRoomClient(messages: [
      message("next-day", offset: 86_400), message("z-tie"), message("a-tie"), message("a-tie")
    ])
    let store = makeStore(client: client)
    await store.load()
    #expect(store.orderedMessages.map(\.message.id.rawValue) == ["a-tie", "z-tie", "next-day"])
    #expect(store.sections.count == 2)
    #expect(store.sections.first?.messages.map(\.message.id.rawValue) == ["a-tie", "z-tie"])
    #expect(store.sections.last?.messages.map(\.message.id.rawValue) == ["next-day"])
  }

  @Test("Own insert events racing acknowledgment do not duplicate identical concurrent sends")
  func racingAcknowledgment() async throws {
    let client = ControlledRoomClient(deferSend: true)
    let store = makeStore(client: client)
    store.start()
    try #require(await waitUntil { store.state == .loaded })
    store.draft = "Same text"
    store.send()
    store.draft = "Same text"
    store.send()
    let localIDs = Set(store.orderedMessages.dropFirst().map(\.id))
    try #require(await waitUntil { await client.pendingSends == 2 })
    await client.finishSend()
    await client.finishSend()
    try #require(await waitUntil { store.orderedMessages.filter { $0.status == .sent }.count == 2 })
    #expect(store.orderedMessages.count == 3)
    #expect(Set(store.orderedMessages.dropFirst().map(\.id)) == localIDs)
    #expect(Set(store.orderedMessages.map(\.message.id)).count == 3)
    store.cancel()
  }

  @Test("Cancel drops late load results and terminates the event subscription")
  func cancelLoad() async throws {
    let client = ControlledRoomClient(deferLoad: true)
    let store = makeStore(client: client)
    store.start()
    try #require(await waitUntil { await client.pendingLoads == 1 })
    store.cancel()
    await client.finishLoad()
    try #require(await waitUntil { await client.terminatedStreams == 1 })
    #expect(store.orderedMessages.isEmpty)
    #expect(store.state == .loading)
  }

  @Test("Router logout reset cancels pending sends and clears private drafts")
  func resetPendingSend() async throws {
    let client = ControlledRoomClient(deferSend: true)
    let router = AppRouter(chatClient: client)
    let store = router.room(for: room, currentUserID: MockSeed.currentUser.id)
    await store.load()
    store.draft = "Private message"
    store.send()
    try #require(await waitUntil { await client.pendingSends == 1 })
    router.reset()
    await client.finishSend()
    try #require(await waitUntil { await client.pendingSends == 0 })
    #expect(store.orderedMessages.isEmpty)
    #expect(store.draft.isEmpty)
    #expect(router.room(for: room, currentUserID: MockSeed.currentUser.id) !== store)
  }

  @Test("Video toolbar request carries the conversation in a typed route")
  func videoRoute() {
    let router = AppRouter(chatClient: MockChatClient())
    router.requestVideo(in: room)
    #expect(router.chats.routes == [.startCall(room)])
    router.reset()
    #expect(router.chats.routes.isEmpty)
  }

  private func makeStore(client: any ChatClient) -> ChatRoomStore {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return ChatRoomStore(
      conversationID: room, currentUserID: MockSeed.currentUser.id, client: client,
      calendar: calendar, now: { MockSeed.date.addingTimeInterval(10) })
  }

  private func message(
    _ id: String, conversationID: ConversationID? = nil, offset: TimeInterval = 0
  ) -> Message {
    Message(
      id: MessageID(id), conversationID: conversationID ?? room, senderID: UserID("user-ava"),
      text: id, sentAt: MockSeed.date.addingTimeInterval(offset), deliveryState: .sent)
  }
}

private actor ControlledRoomClient: ChatClient {
  private let snapshot: [Message]
  private let deferLoad: Bool
  private let deferSend: Bool
  private var failLoadOnce: Bool
  private var failSendOnce: Bool
  private var loads: [CheckedContinuation<[Message], any Error>] = []
  private var sends: [(Message, CheckedContinuation<Message, any Error>)] = []
  private var observers: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]
  private var sequence = 0
  private let base = MockChatClient()
  var pendingLoads: Int { loads.count }
  var pendingSends: Int { sends.count }
  var terminatedStreams = 0

  init(
    messages: [Message] = MockSeed.standard.messages.filter {
      $0.conversationID == ConversationID("conversation-ava")
    },
    deferLoad: Bool = false, deferSend: Bool = false, failLoadOnce: Bool = false,
    failSendOnce: Bool = false
  ) {
    snapshot = messages
    self.deferLoad = deferLoad
    self.deferSend = deferSend
    self.failLoadOnce = failLoadOnce
    self.failSendOnce = failSendOnce
  }

  func messages(in conversationID: ConversationID) async throws -> [Message] {
    if failLoadOnce {
      failLoadOnce = false
      throw ChatError.conversationNotFound
    }
    if deferLoad { return try await withCheckedThrowingContinuation { loads.append($0) } }
    return snapshot
  }

  func finishLoad() { loads.removeFirst().resume(returning: snapshot) }

  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    if failSendOnce {
      failSendOnce = false
      throw ChatError.conversationNotFound
    }
    sequence += 1
    let message = Message(
      id: MessageID("server-\(sequence)"), conversationID: conversationID,
      senderID: MockSeed.currentUser.id, text: text,
      sentAt: MockSeed.date.addingTimeInterval(Double(sequence)), deliveryState: .sent)
    if deferSend {
      return try await withCheckedThrowingContinuation { sends.append((message, $0)) }
    }
    return message
  }

  func finishSend() {
    let (message, continuation) = sends.removeFirst()
    emit(.messageInserted(message))
    emit(
      .deliveryChanged(messageID: message.id, conversationID: message.conversationID, state: .sent))
    continuation.resume(returning: message)
  }

  func emit(_ event: ChatEvent) { for observer in observers.values { observer.yield(event) } }

  func events() async -> AsyncStream<ChatEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.terminate(id) } }
    return stream
  }

  private func terminate(_ id: UUID) {
    observers.removeValue(forKey: id)
    terminatedStreams += 1
  }

  func listConversations() async throws -> [Conversation] { try await base.listConversations() }
  func listUsers() async throws -> [User] { try await base.listUsers() }
  func createDirect(with userID: UserID) async throws -> Conversation {
    try await base.createDirect(with: userID)
  }
  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    try await base.createGroup(name: name, members: members)
  }
}
