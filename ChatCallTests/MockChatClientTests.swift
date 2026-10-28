import Foundation
import Testing

@testable import ChatCall

struct MockChatClientTests {
  @Test("Rooms load newest first and user choices exclude self and duplicate identities")
  func loadsAndDeduplicates() async throws {
    let fixture = MockSeed.standard
    let seed = MockSeed(
      users: fixture.users + [fixture.users[1]],
      conversations: fixture.conversations.reversed(), messages: fixture.messages)
    let client = MockChatClient(seed: seed)
    #expect(
      try await client.listConversations().map(\.id.rawValue) == [
        "conversation-ava", "conversation-team"
      ])
    let users = try await client.listUsers()
    #expect(users.count == 17)
    #expect(users.filter { $0.id == UserID("user-ava") }.count == 1)
    #expect(!users.contains { $0.id == UserID("user-me") })
    #expect(
      try await client.messages(in: ConversationID("conversation-ava")).map(\.text) == [
        "Ready to catch up?"
      ])
  }

  @Test("Direct creation reuses the same member pair and rejects self and unknown users")
  func directReuse() async throws {
    let client = MockChatClient()
    let existing = try await client.createDirect(with: UserID("user-ava"))
    #expect(existing.id == ConversationID("conversation-ava"))
    let created = try await client.createDirect(with: UserID("user-noah"))
    #expect(created.memberIDs == [UserID("user-me"), UserID("user-noah")])
    #expect(try await client.createDirect(with: UserID("user-noah")).id == created.id)
    #expect(try await client.listConversations().count == 3)
    await #expect(throws: ChatError.invalidMembers) {
      try await client.createDirect(with: UserID("user-me"))
    }
    await #expect(throws: ChatError.userNotFound) {
      try await client.createDirect(with: UserID("missing"))
    }
  }

  @Test("Group creation trims its name and uses an ordered unique complete roster")
  func groupCreation() async throws {
    let client = MockChatClient()
    let group = try await client.createGroup(
      name: "  Weekend  ",
      members: [UserID("user-ava"), UserID("user-noah"), UserID("user-ava"), UserID("user-me")])
    #expect(group.name == "Weekend")
    #expect(group.kind == .group)
    #expect(group.memberIDs == [UserID("user-me"), UserID("user-ava"), UserID("user-noah")])
    #expect(try await client.messages(in: group.id).isEmpty)
    #expect(try await client.listConversations().first?.id == group.id)
    await #expect(throws: ChatError.groupNameRequired) {
      try await client.createGroup(
        name: " \n ", members: [UserID("user-ava"), UserID("user-noah")])
    }
    await #expect(throws: ChatError.invalidMembers) {
      try await client.createGroup(name: "Solo", members: [UserID("user-ava")])
    }
    await #expect(throws: ChatError.userNotFound) {
      try await client.createGroup(
        name: "Unknown", members: [UserID("user-ava"), UserID("missing")])
    }
  }

  @Test("Sending inserts immediately then publishes sent and delivered in scheduler order")
  func sendDeliveryOrder() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockChatClient(scheduler: scheduler)
    var iterator = await client.events().makeAsyncIterator()
    let room = ConversationID("conversation-ava")
    let message = try await client.send(text: "  Hello Ava  ", to: room)
    #expect(message.text == "Hello Ava")
    #expect(message.deliveryState == .sending)
    #expect(message.sentAt == Date(timeIntervalSince1970: 1_700_000_001))
    #expect(try await client.messages(in: room).last == message)
    #expect(await iterator.next() == .messageInserted(message))
    guard case .conversationUpdated(let conversation) = await iterator.next() else {
      Issue.record("Sending must also update the conversation preview")
      return
    }
    #expect(conversation.lastMessage == message)
    #expect(await scheduler.waitForPendingSleep())
    await scheduler.advance()
    #expect(
      await iterator.next()
        == .deliveryChanged(messageID: message.id, conversationID: room, state: .sent))
    #expect(try await client.messages(in: room).last?.deliveryState == .sent)
    #expect(await scheduler.waitForPendingSleep())
    await scheduler.advance()
    #expect(
      await iterator.next()
        == .deliveryChanged(messageID: message.id, conversationID: room, state: .delivered))
    #expect(try await client.messages(in: room).last?.deliveryState == .delivered)
    #expect(try await client.listConversations().first?.lastMessage?.deliveryState == .delivered)
  }

  @Test("Blank messages and absent conversations never mutate the repository")
  func invalidSend() async throws {
    let client = MockChatClient()
    await #expect(throws: ChatError.emptyMessage) {
      try await client.send(text: " \n", to: ConversationID("conversation-ava"))
    }
    await #expect(throws: ChatError.conversationNotFound) {
      try await client.send(text: "Hello", to: ConversationID("missing"))
    }
    await #expect(throws: ChatError.conversationNotFound) {
      try await client.messages(in: ConversationID("missing"))
    }
    #expect(try await client.messages(in: ConversationID("conversation-ava")).count == 1)
  }
}

extension ManualDemoScheduler {
  // Test utility only: waits for actor task registration, without elapsed-time sleeps.
  func waitForPendingSleep() async -> Bool {
    for _ in 0..<10_000 {
      if pendingCount > 0 { return true }
      await Task.yield()
    }
    return false
  }
}

struct DemoSchedulerTests {
  @Test("Manual scheduling suspends until the requested deadline and cancels sleepers")
  func deadlinesAndCancellation() async throws {
    let scheduler = ManualDemoScheduler()
    let sleeper = Task { try await scheduler.sleep(for: .seconds(1)) }
    #expect(await scheduler.waitForPendingSleep())
    await scheduler.advance(by: .milliseconds(999))
    #expect(await scheduler.pendingCount == 1)
    await scheduler.advance(by: .milliseconds(1))
    try await sleeper.value
    let canceled = Task { try await scheduler.sleep(for: .seconds(1)) }
    #expect(await scheduler.waitForPendingSleep())
    canceled.cancel()
    await #expect(throws: CancellationError.self) { try await canceled.value }
    #expect(await scheduler.pendingCount == 0)
  }
}
