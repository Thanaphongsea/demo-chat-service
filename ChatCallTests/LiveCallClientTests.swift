import Foundation
import Testing

@testable import ChatCall

nonisolated struct LiveCallClientTests {
  static let alice = User(id: UserID("alice"), displayName: "Alice", initials: "AL")

  struct Rig {
    let client: LiveCallClient
    let router: Router
    let transport: StubTransport
    let clock: Clock
    let ended: Tally
    let keys: Tally
  }

  static func rig(user: User? = alice, configure: (Router) -> Void = { _ in }) -> Rig {
    let router = Router()
    configure(router)
    let transport = StubTransport(reply: { router.reply(for: $0) })
    let api = VoIPClient(
      configuration: VoIPConfiguration(baseURL: URL(string: "https://voip.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let clock = Clock()
    let ended = Tally()
    let keys = Tally()
    let client = LiveCallClient(
      api: api, currentUser: { user }, now: { clock.date },
      makeKey: { "key-\(keys.next())" },
      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
      onSessionEnded: { _ = ended.next() })
    return Rig(client: client, router: router, transport: transport, clock: clock, ended: ended, keys: keys)
  }

  static func conversation(_ id: String, kind: ConversationKind, members: [String]) throws -> Conversation {
    try Conversation(
      id: ConversationID(id), kind: kind, name: "Chat", memberIDs: members.map { UserID($0) },
      updatedAt: Date(timeIntervalSince1970: 1))
  }

  static func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
  }

  static func paths(_ rig: Rig) -> [String] {
    rig.transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
  }

  /// A rig whose inbox shows one ringing call for Alice, polled once so it is her current call.
  static func incomingRig(group: Bool = false, configure: (Router) -> Void = { _ in }) async -> Rig {
    let ringing = CallFixtures.call(
      status: "ringing", group: group, groupStatus: group ? "accepted" : nil, caller: "bob",
      callee: "alice", room: group ? "grp_g1" : "dm_alice_bob",
      participants: group ? [("bob", "joined"), ("alice", "invited")] : nil)
    let rig = rig {
      $0.ok("GET /api/calls", CallFixtures.inbox(calls: [ringing]))
      configure($0)
    }
    await rig.client.poll()
    return rig
  }

  // MARK: start

  @Test("A direct call posts callee_id, the dm room and a key in header and body; it rings")
  func startDirect() async throws {
    let rig = Self.rig { $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "ringing").utf8))) }
    let conversation = try Self.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"])
    let snapshot = try await rig.client.startVideoCall(in: conversation)
    #expect(snapshot.state == .ringing)
    #expect(snapshot.direction == .outgoing)
    #expect(snapshot.kind == .direct)
    #expect(await rig.client.currentCall == snapshot)
    let request = try #require(rig.transport.requests.first)
    let json = Self.body(request)
    #expect(json["callee_id"] as? String == "bob")
    #expect(json["callee_ids"] == nil)
    #expect(json["room_id"] as? String == "dm_alice_bob")
    #expect(json["caller_name"] as? String == "Alice")
    #expect(json["idempotency_key"] as? String == "key-1")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
  }

  @Test("A group call invites everyone but me in one request")
  func startGroup() async throws {
    let wire = CallFixtures.call(
      status: "accepted", group: true, groupStatus: "accepted",
      participants: [("alice", "joined"), ("bob", "invited"), ("carol", "invited")])
    let rig = Self.rig { $0.set("POST /api/calls", StubReply(201, Data(wire.utf8))) }
    let conversation = try Self.conversation("group_g1", kind: .group, members: ["alice", "bob", "carol"])
    let snapshot = try await rig.client.startVideoCall(in: conversation)
    #expect(snapshot.kind == .group)
    #expect(snapshot.state == .ringing)
    let json = Self.body(try #require(rig.transport.requests.first))
    #expect(json["callee_ids"] as? [String] == ["bob", "carol"])
    #expect(json["callee_id"] == nil)
    #expect(json["room_id"] as? String == "grp_g1")
  }

  @Test("Fifteen invitees is the limit; sixteen is a capacity error with no request")
  func capacity() async throws {
    let fifteen = (1...15).map { "u\($0)" }
    let wire = CallFixtures.call(status: "accepted", group: true, groupStatus: "accepted")
    let rig = Self.rig { $0.set("POST /api/calls", StubReply(201, Data(wire.utf8))) }
    _ = try await rig.client.startVideoCall(
      in: try Self.conversation("group_g1", kind: .group, members: ["alice"] + fifteen))
    let full = Self.rig()
    await #expect(throws: CallError.capacityExceeded(maximum: 16)) {
      try await full.client.startVideoCall(
        in: try Self.conversation("group_g1", kind: .group, members: ["alice"] + fifteen + ["u16"]))
    }
    #expect(full.transport.requests.isEmpty)
  }

  @Test("Invalid conversations and a signed-out user never reach the network")
  func startRejections() async throws {
    let rig = Self.rig()
    await #expect(throws: CallError.invalidConversation) {
      try await rig.client.startVideoCall(
        in: try Self.conversation("c2c_bob", kind: .direct, members: ["carol", "bob"]))
    }
    await #expect(throws: CallError.invalidConversation) {
      try await rig.client.startVideoCall(
        in: try Self.conversation("group_g1", kind: .group, members: ["alice"]))
    }
    await #expect(throws: CallError.invalidConversation) {
      try await rig.client.startVideoCall(
        in: try Self.conversation("nonsense", kind: .group, members: ["alice", "bob"]))
    }
    let signedOut = Self.rig(user: nil)
    await #expect(throws: VoIPError.unauthorized) {
      try await signedOut.client.startVideoCall(
        in: try Self.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"]))
    }
    #expect(rig.transport.requests.isEmpty && signedOut.transport.requests.isEmpty)
  }

  @Test("A second call while one is live is refused locally; a server 409 on create means busy")
  func busy() async throws {
    let rig = Self.rig { $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "ringing").utf8))) }
    let conversation = try Self.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"])
    _ = try await rig.client.startVideoCall(in: conversation)
    await #expect(throws: CallError.callAlreadyInProgress) {
      try await rig.client.startVideoCall(in: conversation)
    }
    let busy = Self.rig { $0.set("POST /api/calls", StubReply(409, Data(#"{"error":"busy"}"#.utf8))) }
    await #expect(throws: CallError.callAlreadyInProgress) {
      try await busy.client.startVideoCall(in: conversation)
    }
  }

  @Test("After a timeout the next attempt reuses the first key; after a definitive answer it does not")
  func idempotencyAcrossRetries() async throws {
    let conversation = try Self.conversation("group_g1", kind: .group, members: ["alice", "bob", "carol"])
    let lost = Self.rig { $0.set("POST /api/calls", StubReply(503)) }
    await #expect(throws: VoIPError.server(503)) { try await lost.client.startVideoCall(in: conversation) }
    lost.router.set(
      "POST /api/calls",
      StubReply(201, Data(CallFixtures.call(status: "accepted", group: true, groupStatus: "accepted").utf8)))
    _ = try await lost.client.startVideoCall(in: conversation)
    let keys = Set(lost.transport.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") })
    #expect(keys == ["key-1"])

    let rejected = Self.rig { $0.set("POST /api/calls", StubReply(409, Data(#"{"error":"busy"}"#.utf8))) }
    _ = try? await rejected.client.startVideoCall(in: conversation)
    rejected.router.set(
      "POST /api/calls",
      StubReply(201, Data(CallFixtures.call(status: "accepted", group: true, groupStatus: "accepted").utf8)))
    _ = try await rejected.client.startVideoCall(in: conversation)
    #expect(
      rejected.transport.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        == ["key-1", "key-2"])
  }

  // MARK: answer, decline, end, join

  @Test("Answering posts accept and becomes active; declining posts reject")
  func answerAndDecline() async throws {
    let rig = await Self.incomingRig {
      $0.ok("POST /api/calls/call-1/accept", CallFixtures.call(status: "accepted", caller: "bob", callee: "alice"))
    }
    let incoming = try #require(await rig.client.currentCall)
    #expect(incoming.state == .incoming)
    let answered = try await rig.client.answer(callID: incoming.id)
    #expect(answered.state == .active)
    #expect(Self.body(try #require(rig.transport.requests.last))["peer_id"] as? String == "alice")

    let decline = await Self.incomingRig {
      $0.ok("POST /api/calls/call-1/reject", CallFixtures.call(status: "rejected", caller: "bob", callee: "alice"))
    }
    let declined = try await decline.client.decline(callID: CallID("call-1"))
    #expect(declined.state == .declined)
    #expect(Self.paths(decline).last == "POST /api/calls/call-1/reject")
  }

  @Test("Declining a group call keeps Rejoin available and lists it in history")
  func declineGroupCanRejoin() async throws {
    let rig = await Self.incomingRig(group: true) {
      $0.ok(
        "POST /api/calls/call-1/reject",
        CallFixtures.call(
          status: "rejected", group: true, groupStatus: "accepted", canJoin: true, caller: "bob",
          room: "grp_g1", participants: [("bob", "joined"), ("alice", "rejected")]))
    }
    let declined = try await rig.client.decline(callID: CallID("call-1"))
    #expect(declined.state == .declined && declined.canJoin)
    #expect(await rig.client.history().map(\.canJoin) == [true])
  }

  @Test("End picks cancel, end or leave by call kind and state; only the creator can end all")
  func endActions() async throws {
    let direct = Self.rig {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "ringing").utf8)))
      $0.ok("POST /api/calls/call-1/cancel", CallFixtures.call(status: "cancelled"))
    }
    _ = try await direct.client.startVideoCall(in: try Self.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"]))
    #expect(try await direct.client.end(callID: CallID("call-1")).state == .ended)
    #expect(Self.paths(direct).last == "POST /api/calls/call-1/cancel")

    let accepted = Self.rig {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "accepted").utf8)))
      $0.ok("POST /api/calls/call-1/end", CallFixtures.call(status: "ended"))
    }
    _ = try await accepted.client.startVideoCall(in: try Self.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"]))
    _ = try await accepted.client.end(callID: CallID("call-1"))
    #expect(Self.paths(accepted).last == "POST /api/calls/call-1/end")

    let activeGroup = CallFixtures.call(
      status: "accepted", group: true, groupStatus: "accepted",
      participants: [("alice", "joined"), ("bob", "joined")])
    let group = Self.rig {
      $0.set("POST /api/calls", StubReply(201, Data(activeGroup.utf8)))
      $0.ok(
        "POST /api/calls/call-1/leave",
        CallFixtures.call(
          status: "ended", group: true, groupStatus: "accepted", canJoin: true,
          participants: [("alice", "left"), ("bob", "joined")]))
      $0.ok(
        "POST /api/calls/call-1/end-all",
        CallFixtures.call(status: "ended", group: true, groupStatus: "ended"))
    }
    let conversation = try Self.conversation("group_g1", kind: .group, members: ["alice", "bob", "carol"])
    _ = try await group.client.startVideoCall(in: conversation)
    let left = try await group.client.end(callID: CallID("call-1"))
    #expect(Self.paths(group).last == "POST /api/calls/call-1/leave")
    // The creator leaving a group others still occupy is ended for them but can rejoin; it is not "ended for all".
    #expect(left.state == .ended && left.canJoin)

    let everyone = Self.rig {
      $0.set("POST /api/calls", StubReply(201, Data(activeGroup.utf8)))
      $0.ok("POST /api/calls/call-1/end-all", CallFixtures.call(status: "ended", group: true, groupStatus: "ended"))
    }
    _ = try await everyone.client.startVideoCall(in: conversation)
    let all = try await everyone.client.endForEveryone(callID: CallID("call-1"))
    #expect(all.state == .ended && !all.canJoin)
    #expect(Self.paths(everyone).last == "POST /api/calls/call-1/end-all")

    let invitee = await Self.incomingRig(group: true)
    await #expect(throws: CallError.invalidTransition) {
      try await invitee.client.endForEveryone(callID: CallID("call-1"))
    }
    await #expect(throws: CallError.invalidTransition) { try await invitee.client.end(callID: CallID("call-1")) }
  }

  @Test("Joining a joinable call posts join; it is refused while another call is live or by the server")
  func join() async throws {
    let joinable = CallFixtures.call(
      status: "missed", group: true, groupStatus: "accepted", canJoin: true, caller: "bob",
      participants: [("bob", "joined"), ("alice", "missed")])
    let rig = Self.rig {
      $0.ok("GET /api/calls", CallFixtures.inbox(joinable: [joinable]))
      $0.ok(
        "POST /api/calls/call-1/join",
        CallFixtures.call(
          status: "accepted", group: true, groupStatus: "accepted", canJoin: true, caller: "bob",
          participants: [("bob", "joined"), ("alice", "joined")]))
    }
    await rig.client.poll()
    #expect(await rig.client.history().map(\.canJoin) == [true])
    let joined = try await rig.client.join(callID: CallID("call-1"))
    #expect(joined.state == .active && !joined.canJoin)
    await #expect(throws: CallError.callAlreadyInProgress) { try await rig.client.join(callID: CallID("call-2")) }

    let refused = Self.rig {
      $0.set("POST /api/calls/call-1/join", StubReply(409, Data(#"{"error":"group ended"}"#.utf8)))
    }
    await #expect(throws: CallError.invalidTransition) { try await refused.client.join(callID: CallID("call-1")) }
  }

  // MARK: local controls and unsupported demos

  @Test("Media toggles change the snapshot locally without a request; demos are unsupported")
  func controlsAndDemos() async throws {
    let rig = Self.rig {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "accepted").utf8)))
    }
    _ = try await rig.client.startVideoCall(in: try Self.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"]))
    let before = rig.transport.requests.count
    let muted = try await rig.client.setMicrophoneEnabled(false, callID: CallID("call-1"))
    #expect(!muted.microphoneEnabled)
    #expect(try await rig.client.setCameraEnabled(false, callID: CallID("call-1")).cameraEnabled == false)
    #expect(try await rig.client.setSpeakerEnabled(false, callID: CallID("call-1")).speakerEnabled == false)
    #expect(try await rig.client.flipCamera(callID: CallID("call-1")).cameraPosition == .back)
    #expect(rig.transport.requests.count == before)
    await #expect(throws: CallError.unsupported) { try await rig.client.demoIncomingCall(kind: .direct) }
    await #expect(throws: CallError.unsupported) { try await rig.client.demoMissedCall(kind: .group) }
    await #expect(throws: CallError.callNotFound) {
      try await rig.client.setMicrophoneEnabled(true, callID: CallID("other"))
    }
  }

  @Test("An unauthorised answer reports the ended session and still throws")
  func sessionEnd() async throws {
    let rig = await Self.incomingRig { $0.set("POST /api/calls/call-1/accept", StubReply(401)) }
    await #expect(throws: VoIPError.unauthorized) { try await rig.client.answer(callID: CallID("call-1")) }
    #expect(rig.ended.count == 1)
  }
}
