import Foundation
import Testing

@testable import ChatCall

struct MockCallClientTests {
  @Test("Outgoing calls ring before becoming active and controls update the same call")
  func outgoingAndControls() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockCallClient(scheduler: scheduler)
    let probe = EventProbe<CallEvent>()
    await probe.start(stream: client.events())
    defer { Task { await probe.cancel() } }
    let call = try await client.startVideoCall(in: MockSeed.standard.conversations[0])
    #expect(call.state == .ringing)
    #expect(call.participants.map(\.id.rawValue) == ["user-me", "user-ava"])
    try #require(await waitUntil { await probe.count >= 1 })
    #expect(await probe.value(at: 0) == .callUpdated(call))
    #expect(await scheduler.waitForPendingSleep())
    await scheduler.advance()
    try #require(await waitUntil { await probe.count >= 2 })
    guard case .callUpdated(let active) = await probe.value(at: 1) else {
      Issue.record("A ringing call must publish its active transition")
      return
    }
    #expect(active.state == .active)
    #expect(active.id == call.id)
    #expect(
      try await client.setMicrophoneEnabled(false, callID: call.id).microphoneEnabled == false)
    #expect(try await client.setCameraEnabled(false, callID: call.id).cameraEnabled == false)
    #expect(try await client.setSpeakerEnabled(false, callID: call.id).speakerEnabled == false)
    #expect(try await client.flipCamera(callID: call.id).cameraPosition == .back)
    #expect(try await client.flipCamera(callID: call.id).cameraPosition == .front)
    let ended = try await client.end(callID: call.id)
    #expect(ended.state == .ended)
    #expect(await client.history() == [ended])
  }

  @Test("Group video calls include every current member and permit exactly 16 people")
  func groupCallsAllAndCapacity() async throws {
    let seed = MockSeed.standard
    let client = MockCallClient()
    let group = try await client.startVideoCall(in: seed.conversations[1])
    #expect(group.kind == .group)
    #expect(group.participants.map(\.id.rawValue) == ["user-me", "user-ava", "user-noah"])
    _ = try await client.end(callID: group.id)
    let sixteen = try Conversation(
      id: ConversationID("sixteen"), kind: .group, name: "All hands",
      memberIDs: Array(seed.users.prefix(16)).map(\.id), updatedAt: MockSeed.date)
    let accepted = try await client.startVideoCall(in: sixteen)
    #expect(accepted.participants.count == 16)
    _ = try await client.end(callID: accepted.id)
    let seventeen = try Conversation(
      id: ConversationID("seventeen"), kind: .group, name: "Too many",
      memberIDs: Array(seed.users.prefix(17)).map(\.id), updatedAt: MockSeed.date)
    await #expect(throws: CallError.capacityExceeded(maximum: 16)) {
      try await client.startVideoCall(in: seventeen)
    }
    #expect(await client.currentCall?.id == accepted.id)
  }

  @Test("Incoming direct and group scenarios remain answerable with immediate scheduling")
  func incomingScenarios() async throws {
    let client = MockCallClient()
    let direct = try await client.demoIncomingCall(kind: .direct)
    #expect(direct.id == CallID("call-1"))
    #expect(direct.conversationID == ConversationID("conversation-ava"))
    #expect(direct.state == .incoming)
    #expect(direct.direction == .incoming)
    #expect(direct.startedAt == Date(timeIntervalSince1970: 1_700_000_001))
    #expect(try await client.answer(callID: direct.id).state == .active)
    _ = try await client.end(callID: direct.id)
    let group = try await client.demoIncomingCall(kind: .group)
    #expect(group.conversationID == ConversationID("conversation-team"))
    #expect(group.participants.count == 3)
    #expect(try await client.decline(callID: group.id).state == .declined)
    let missed = try await client.demoMissedCall(kind: .group)
    #expect(missed.state == .missed)
    #expect(await client.history().map(\.state) == [.missed, .declined, .ended])
  }

  @Test("Unknown IDs, answering outgoing calls, busy calls, and terminal controls are rejected")
  func invalidTransitions() async throws {
    let client = MockCallClient()
    await #expect(throws: CallError.callNotFound) {
      try await client.answer(callID: CallID("missing"))
    }
    let call = try await client.startVideoCall(in: MockSeed.standard.conversations[0])
    await #expect(throws: CallError.invalidTransition) { try await client.answer(callID: call.id) }
    await #expect(throws: CallError.invalidTransition) { try await client.decline(callID: call.id) }
    await #expect(throws: CallError.callAlreadyInProgress) {
      try await client.demoIncomingCall(kind: .group)
    }
    _ = try await client.end(callID: call.id)
    await #expect(throws: CallError.invalidTransition) { try await client.end(callID: call.id) }
    await #expect(throws: CallError.invalidTransition) {
      try await client.setCameraEnabled(false, callID: call.id)
    }
    let noLocal = try Conversation(
      id: ConversationID("no-local"), kind: .direct, name: "Others",
      memberIDs: [UserID("user-ava"), UserID("user-noah")], updatedAt: MockSeed.date)
    await #expect(throws: CallError.invalidConversation) {
      try await client.startVideoCall(in: noLocal)
    }
    let unknown = try Conversation(
      id: ConversationID("unknown"), kind: .direct, name: "Unknown",
      memberIDs: [UserID("user-me"), UserID("missing")], updatedAt: MockSeed.date)
    await #expect(throws: CallError.userNotFound) { try await client.startVideoCall(in: unknown) }
  }

  @Test("Reconnect resumes on manual advance and ending prevents delayed reactivation")
  func reconnectAndEndCancellation() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockCallClient(scheduler: scheduler)
    let incoming = try await client.demoIncomingCall(kind: .direct)
    _ = try await client.answer(callID: incoming.id)
    #expect(try await client.demoReconnect(callID: incoming.id).state == .reconnecting)
    #expect(await scheduler.waitForPendingSleep())
    await scheduler.advance()
    #expect(await client.waitForState(.active))
    _ = try await client.end(callID: incoming.id)
    let outgoing = try await client.startVideoCall(in: MockSeed.standard.conversations[0])
    #expect(await scheduler.waitForPendingSleep())
    _ = try await client.end(callID: outgoing.id)
    await scheduler.advance(by: .seconds(10))
    #expect(await client.currentCall?.state == .ended)
    #expect(await client.history().count == 2)
  }
}

extension MockCallClient {
  func waitForState(_ state: CallState) async -> Bool {
    for _ in 0..<10_000 {
      if currentCall?.state == state { return true }
      await Task.yield()
    }
    return false
  }
}
