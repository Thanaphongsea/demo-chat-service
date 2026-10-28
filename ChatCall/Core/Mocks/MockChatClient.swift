import Foundation

actor MockChatClient: ChatClient {
  private let users: [User]
  private var conversations: [ConversationID: Conversation]
  private var storedMessages: [ConversationID: [Message]]
  private let scheduler: any DemoScheduler
  private var sequence = 0
  private var observers: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]

  init(seed: MockSeed = .standard, scheduler: any DemoScheduler = ImmediateDemoScheduler()) {
    var seen: Set<UserID> = []
    users = seed.users.filter { seen.insert($0.id).inserted }
    conversations = seed.conversations.reduce(into: [:]) { $0[$1.id] = $1 }
    storedMessages = Dictionary(grouping: seed.messages, by: \.conversationID)
    self.scheduler = scheduler
  }

  func listConversations() async throws -> [Conversation] {
    conversations.values.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id.rawValue < $1.id.rawValue : $0.updatedAt > $1.updatedAt
    }
  }

  func listUsers() async throws -> [User] { users.filter { $0.id != MockSeed.currentUser.id } }

  func messages(in conversationID: ConversationID) async throws -> [Message] {
    guard conversations[conversationID] != nil else { throw ChatError.conversationNotFound }
    return (storedMessages[conversationID] ?? []).sorted {
      $0.sentAt == $1.sentAt ? $0.id.rawValue < $1.id.rawValue : $0.sentAt < $1.sentAt
    }
  }

  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { throw ChatError.emptyMessage }
    guard let conversation = conversations[conversationID] else {
      throw ChatError.conversationNotFound
    }
    sequence += 1
    let message = Message(
      id: MessageID("message-created-\(sequence)"), conversationID: conversationID,
      senderID: MockSeed.currentUser.id, text: trimmedText,
      sentAt: MockSeed.date.addingTimeInterval(Double(sequence)), deliveryState: .sending)
    storedMessages[conversationID, default: []].append(message)
    let updated = try replacingPreview(in: conversation, with: message)
    conversations[conversationID] = updated
    publish(.messageInserted(message))
    publish(.conversationUpdated(updated))
    Task { [weak self, scheduler] in
      do {
        try await scheduler.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
        await self?.updateDelivery(message, state: .sent)
        try await scheduler.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
        await self?.updateDelivery(message, state: .delivered)
      } catch {
        // Cancellation leaves the last visible delivery state intact.
      }
    }
    return message
  }

  func createDirect(with userID: UserID) async throws -> Conversation {
    guard userID != MockSeed.currentUser.id else { throw ChatError.invalidMembers }
    guard let user = users.first(where: { $0.id == userID }) else { throw ChatError.userNotFound }
    let members = [MockSeed.currentUser.id, userID]
    if let existing = conversations.values.first(where: {
      $0.kind == .direct && Set($0.memberIDs) == Set(members)
    }) {
      return existing
    }
    return try insertConversation(kind: .direct, name: user.displayName, members: members)
  }

  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChatError.groupNameRequired
    }
    var seen: Set<UserID> = []
    let roster = ([MockSeed.currentUser.id] + members).filter { seen.insert($0).inserted }
    guard roster.count >= 3 else { throw ChatError.invalidMembers }
    guard roster.allSatisfy({ id in users.contains { $0.id == id } }) else {
      throw ChatError.userNotFound
    }
    return try insertConversation(kind: .group, name: name, members: roster)
  }

  func events() async -> AsyncStream<ChatEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  private func insertConversation(
    kind: ConversationKind, name: String, members: [UserID]
  ) throws -> Conversation {
    sequence += 1
    let conversation = try Conversation(
      id: ConversationID("conversation-created-\(sequence)"),
      kind: kind, name: name, memberIDs: members,
      updatedAt: MockSeed.date.addingTimeInterval(Double(sequence)))
    conversations[conversation.id] = conversation
    publish(.conversationUpdated(conversation))
    return conversation
  }

  private func updateDelivery(_ message: Message, state: DeliveryState) {
    guard
      let index = storedMessages[message.conversationID]?.firstIndex(where: { $0.id == message.id })
    else { return }
    let updated = Message(
      id: message.id, conversationID: message.conversationID, senderID: message.senderID,
      text: message.text, sentAt: message.sentAt, deliveryState: state)
    storedMessages[message.conversationID]?[index] = updated
    if let conversation = conversations[message.conversationID] {
      if conversation.lastMessage?.id == message.id {
        conversations[message.conversationID] = try? replacingPreview(
          in: conversation, with: updated)
      }
    }
    publish(
      .deliveryChanged(messageID: message.id, conversationID: message.conversationID, state: state))
  }

  private func replacingPreview(
    in conversation: Conversation, with message: Message
  ) throws -> Conversation {
    try Conversation(
      id: conversation.id, kind: conversation.kind, name: conversation.name,
      memberIDs: conversation.memberIDs, unreadCount: conversation.unreadCount,
      lastMessage: message, updatedAt: message.sentAt)
  }

  private func publish(_ event: ChatEvent) {
    for observer in observers.values { observer.yield(event) }
  }
  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
