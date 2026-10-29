import Foundation
import Testing

@testable import ChatCall

nonisolated private let callSmokePassword = ProcessInfo.processInfo.environment["CHATCALL_LIVE_PASSWORD"] ?? ""
nonisolated private let callSmokeVoIP = ProcessInfo.processInfo.environment["CHATCALL_VOIP_URL"] ?? ""
nonisolated private let callSmokeEnabled = !callSmokePassword.isEmpty && URL(string: callSmokeVoIP)?.host != nil

/// Opt-in signalling check against a real VoIP service: u_alice calls u_bob, u_bob sees and answers it, then
/// u_alice ends it. Needs `TEST_RUNNER_CHATCALL_LIVE_PASSWORD` and `TEST_RUNNER_CHATCALL_VOIP_URL` (xcodebuild
/// strips the prefix). No media: the peers are not started. This has never been run: no VoIP origin was reachable.
@Suite(.enabled(if: callSmokeEnabled))
nonisolated struct LiveCallSmokeTests {
  private func client(_ name: String, media: MediaDependencies? = nil) async throws -> (LiveCallClient, User) {
    let auth = LiveAuthClient(
      configuration: .dev, store: InMemorySessionStore(), deviceID: "ios-qa-call-\(name)")
    let session = try await auth.signIn(credentials: Credentials(identity: name, password: callSmokePassword))
    let api = VoIPClient(
      configuration: VoIPConfiguration(baseURL: URL(string: callSmokeVoIP)!), tokens: auth)
    return (LiveCallClient(api: api, currentUser: { session.user }, media: media), session.user)
  }

  private func waitFor(_ client: LiveCallClient, _ state: CallState) async -> Bool {
    for _ in 0..<40 {
      await client.poll()
      if await client.currentCall?.state == state { return true }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return false
  }

  @Test("Alice rings Bob; Bob answers; Alice ends it")
  func directCall() async throws {
    let (alice, aliceUser) = try await client("u_alice")
    let (bob, bobUser) = try await client("u_bob")
    let conversation = try Conversation(
      id: ConversationID("c2c_u_bob"), kind: .direct, name: "Bob",
      memberIDs: [aliceUser.id, bobUser.id], updatedAt: .now)
    let started = try await alice.startVideoCall(in: conversation)
    print("CALLSMOKE started:", started.id.rawValue, started.state)
    #expect(await waitFor(bob, .incoming))
    let answered = try await bob.answer(callID: started.id)
    print("CALLSMOKE answered:", answered.state)
    #expect(answered.state == .active)
    #expect(await waitFor(alice, .active))
    let ended = try await alice.end(callID: started.id)
    print("CALLSMOKE ended:", ended.state)
    #expect(ended.state == .ended)
    #expect(await waitFor(bob, .ended))
  }

  @Test("Group: Alice rings the group, Bob declines then rejoins, Alice ends it for everyone")
  func groupCall() async throws {
    let (alice, aliceUser) = try await client("u_alice")
    let (bob, bobUser) = try await client("u_bob")
    let conversation = try Conversation(
      id: ConversationID("group_g_test"), kind: .group, name: "g_test",
      memberIDs: [aliceUser.id, bobUser.id, UserID("u_eve")], updatedAt: .now)
    let started = try await alice.startVideoCall(in: conversation)
    print("CALLSMOKE group started:", started.id.rawValue, started.state, started.kind)
    #expect(started.kind == .group)
    #expect(await waitFor(bob, .incoming))
    let declined = try await bob.decline(callID: started.id)
    print("CALLSMOKE group declined:", declined.state, "canJoin=\(declined.canJoin)")
    #expect(declined.state == .declined)
    #expect(declined.canJoin)
    #expect(await bob.history().contains { $0.id == started.id && $0.canJoin })
    let rejoined = try await bob.join(callID: started.id)
    print("CALLSMOKE group rejoined:", rejoined.state)
    #expect(rejoined.state == .active)
    #expect(await waitFor(alice, .active))
    let left = try await bob.end(callID: started.id)
    print("CALLSMOKE group bob left:", left.state, "canJoin=\(left.canJoin)")
    #expect(left.state == .ended)
    let ended = try await alice.endForEveryone(callID: started.id)
    print("CALLSMOKE group ended for everyone:", ended.state, "canJoin=\(ended.canJoin)")
    #expect(ended.state == .ended)
    #expect(!ended.canJoin)
  }

  /// Production path with real WebRTC on both sides in one process: does media come up and stay up?
  @Test("Media: Alice and Bob connect with WebRTC and the call stays active")
  func mediaCall() async throws {
    let (alice, aliceUser) = try await client("u_alice", media: .live)
    let (bob, bobUser) = try await client("u_bob", media: .live)
    let conversation = try Conversation(
      id: ConversationID("c2c_u_bob"), kind: .direct, name: "Bob",
      memberIDs: [aliceUser.id, bobUser.id], updatedAt: .now)
    let started = try await alice.startVideoCall(in: conversation)
    #expect(await waitFor(bob, .incoming))
    _ = try await bob.answer(callID: started.id)
    var trail: [String] = []
    for second in 0..<20 {
      await alice.poll()
      await bob.poll()
      let a = await alice.currentCall
      let b = await bob.currentCall
      trail.append("t\(second) alice=\(a?.state.label ?? "-")/\(a?.participants.count ?? 0) bob=\(b?.state.label ?? "-")/\(b?.participants.count ?? 0)")
      try? await Task.sleep(for: .seconds(1))
    }
    print("CALLSMOKE media trail:\n" + trail.joined(separator: "\n"))
    let final = await alice.currentCall
    #expect(final?.state == .active)
    #expect(final?.participants.count == 2)
    _ = try? await alice.end(callID: started.id)
    await alice.stopMonitoring()
    await bob.stopMonitoring()
  }
}

private nonisolated extension CallState {
  var label: String {
    switch self {
    case .incoming: "incoming"
    case .ringing: "ringing"
    case .active: "active"
    case .reconnecting: "reconnecting"
    case .declined: "declined"
    case .missed: "missed"
    case .ended: "ended"
    }
  }
}
