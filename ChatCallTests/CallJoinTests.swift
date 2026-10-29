import Foundation
import Testing

@testable import ChatCall

@MainActor
struct CallJoinTests {
  private func groupConversation() async throws -> Conversation {
    try #require(try await MockChatClient().listConversations().first { $0.kind == .group })
  }

  @Test("A missed group call can be joined from history and becomes the live call")
  func joinFromHistory() async throws {
    let client = MockCallClient()
    _ = try await client.demoMissedCall(kind: .group)
    let store = CallStore(client: client, chatClient: MockChatClient())
    await store.start()
    let missed = try #require(store.history.first)
    #expect(missed.canJoin)
    #expect(missed.joinTitle == "Join")
    await store.join(missed)
    #expect(store.call?.id == missed.id)
    #expect(store.call?.state == .active)
    #expect(store.isPresented)
    #expect(store.history.isEmpty)
    store.reset()
  }

  @Test("A declined or left call is rejoined, not joined")
  func rejoinTitle() throws {
    let base = CallSnapshot(
      id: CallID("c"), conversationID: ConversationID("group_g"), kind: .group, direction: .incoming,
      state: .declined, participants: [], startedAt: .now, microphoneEnabled: true,
      cameraEnabled: true, speakerEnabled: true, cameraPosition: .front, canJoin: true)
    #expect(base.joinTitle == "Rejoin")
  }

  @Test("History without can_join cannot be joined")
  func noJoinWithoutCapability() async throws {
    let client = MockCallClient()
    _ = try await client.demoMissedCall(kind: .direct)
    let store = CallStore(client: client, chatClient: MockChatClient())
    await store.start()
    let missed = try #require(store.history.first)
    #expect(!missed.canJoin)
    await store.join(missed)
    #expect(store.call == nil)
    #expect(store.history.count == 1)
    store.reset()
  }

  @Test("The creator of a group call can end it for everyone; a direct call cannot")
  func endForEveryone() async throws {
    let store = CallStore(client: MockCallClient(), chatClient: MockChatClient())
    await store.startVideo(in: try await groupConversation().id)
    #expect(store.call?.kind == .group)
    await store.endForEveryone()
    #expect(store.call?.state == .ended)
    store.dismiss()

    let direct = try #require(try await MockChatClient().listConversations().first { $0.kind == .direct })
    await store.startVideo(in: direct.id)
    await store.endForEveryone()
    #expect(store.call?.state != .ended)
    store.reset()
  }

  @Test("The local tile and audio-only marker follow the snapshot's own user, not the mock user")
  func localUserFromSnapshot() throws {
    let alice = User(id: UserID("alice"), displayName: "Alice", initials: "AL")
    let bob = User(id: UserID("bob"), displayName: "Bob", initials: "BO")
    let snapshot = CallSnapshot(
      id: CallID("c"), conversationID: ConversationID("c2c_bob"), kind: .direct, direction: .outgoing,
      state: .active, participants: [alice, bob], startedAt: .now, microphoneEnabled: true,
      cameraEnabled: false, speakerEnabled: true, cameraPosition: .front, localUserID: alice.id)
    let store = CallStore(client: MockCallClient(), chatClient: MockChatClient())
    store.receive(.callUpdated(snapshot))
    #expect(store.page.localUser == alice)
    #expect(store.page.tiles.map(\.user.id.rawValue) == ["alice", "bob"])
    #expect(store.page.tiles.first?.isVideoEnabled == false)
    #expect(snapshot.displayName == "Bob")
    store.reset()
  }

  @Test("Demo actions are shown by default and hidden for a live client")
  func demoFlag() {
    #expect(CallStore(client: MockCallClient(), chatClient: MockChatClient()).demoEnabled)
    #expect(!CallStore(client: MockCallClient(), chatClient: MockChatClient(), demoEnabled: false).demoEnabled)
  }
}
