import Foundation
import Testing

@testable import ChatCall

nonisolated struct LiveCallMonitoringTests {
  private typealias Rig = LiveCallClientTests.Rig

  private static func ringingInbox(id: String = "call-1") -> String {
    CallFixtures.inbox(calls: [
      CallFixtures.call(id: id, status: "ringing", caller: "bob", callee: "alice")
    ])
  }

  private static let direct = try! LiveCallClientTests.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"])
  private static let group = try! LiveCallClientTests.conversation("group_g1", kind: .group, members: ["alice", "bob", "carol"])

  private static func paths(_ rig: Rig) -> [String] { LiveCallClientTests.paths(rig) }

  private func started(
    _ status: String, conversation: Conversation = LiveCallMonitoringTests.direct,
    group: Bool = false, configure: (Router) -> Void = { _ in }
  ) async throws -> Rig {
    let wire = CallFixtures.call(
      status: status, group: group, groupStatus: group ? "accepted" : nil,
      participants: group ? [("alice", "joined"), ("bob", "invited"), ("carol", "invited")] : nil)
    let rig = LiveCallClientTests.rig {
      $0.set("POST /api/calls", StubReply(201, Data(wire.utf8)))
      configure($0)
    }
    _ = try await rig.client.startVideoCall(in: conversation)
    return rig
  }

  // MARK: discovery

  @Test("A ringing call in the inbox becomes the incoming call once")
  func discoversIncoming() async throws {
    let rig = LiveCallClientTests.rig {
      $0.ok("GET /api/calls", Self.ringingInbox())
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "ringing", caller: "bob", callee: "alice"))
    }
    await rig.client.poll()
    let incoming = try #require(await rig.client.currentCall)
    #expect(incoming.state == .incoming && incoming.direction == .incoming)
    #expect(incoming.conversationID == ConversationID("c2c_bob"))
    #expect(Self.paths(rig) == ["GET /api/calls"])
    await rig.client.poll()
    #expect(Self.paths(rig) == ["GET /api/calls", "GET /api/calls/call-1"])
    #expect(await rig.client.currentCall == incoming)
  }

  @Test("Observers receive the incoming call; polling starts with the first subscriber and stops with the last")
  func monitorLoop() async throws {
    let rig = LiveCallClientTests.rig { $0.ok("GET /api/calls", Self.ringingInbox()) }
    let stream = await rig.client.events()
    var iterator = stream.makeAsyncIterator()
    guard case .callUpdated(let incoming)? = await iterator.next() else {
      Issue.record("no incoming event")
      return
    }
    #expect(incoming.state == .incoming)
    await rig.client.stopMonitoring()
    #expect(await iterator.next() == nil)
    #expect(await rig.client.currentCall == nil)
  }

  @Test("A stale inbox never revives a call already handled, nor replaces a call started meanwhile")
  func staleInbox() async throws {
    let handled = await LiveCallClientTests.incomingRig {
      $0.ok("POST /api/calls/call-1/reject", CallFixtures.call(status: "rejected", caller: "bob", callee: "alice"))
    }
    _ = try await handled.client.decline(callID: CallID("call-1"))
    let before = await handled.client.currentCall
    await handled.client.poll()  // the inbox still lists the ringing call
    #expect(await handled.client.currentCall == before)
    #expect(before?.state == .declined)

    let gate = AsyncStream<Void>.makeStream()
    let rig = LiveCallClientTests.rig {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "ringing").utf8)))
    }
    let slowTransport = StubTransport(reply: { request in
      if request.url?.path == "/api/calls", request.httpMethod == "GET" {
        for await _ in gate.stream { break }
        return StubReply(200, Data(Self.ringingInbox(id: "stale").utf8))
      }
      return rig.router.reply(for: request)
    })
    let api = VoIPClient(
      configuration: VoIPConfiguration(baseURL: URL(string: "https://voip.example.test")!),
      tokens: StaticTokens(), transport: slowTransport, sleep: { _ in })
    let client = LiveCallClient(
      api: api, currentUser: { LiveCallClientTests.alice }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
    let polling = Task { await client.poll() }
    while slowTransport.requests.isEmpty { await Task.yield() }
    let own = try await client.startVideoCall(in: Self.direct)
    gate.continuation.yield()
    await polling.value
    #expect(await client.currentCall == own)
  }

  @Test("Joinable calls with can_join are kept for history; others are dropped")
  func joinableList() async throws {
    let rig = LiveCallClientTests.rig {
      $0.ok(
        "GET /api/calls",
        CallFixtures.inbox(joinable: [
          CallFixtures.call(
            id: "a", status: "missed", group: true, groupStatus: "accepted", canJoin: true, caller: "bob",
            participants: [("bob", "joined"), ("alice", "missed")]),
          CallFixtures.call(
            id: "b", status: "rejected", group: true, groupStatus: "accepted", caller: "bob",
            participants: [("bob", "joined"), ("alice", "rejected")])
        ]))
    }
    await rig.client.poll()
    #expect(await rig.client.history().map(\.id.rawValue) == ["a"])
    #expect(await rig.client.currentCall == nil)
  }

  // MARK: heartbeat and refresh

  @Test("Heartbeat runs every 10 seconds while active; other cycles only read the state")
  func heartbeatCadence() async throws {
    let rig = try await started("accepted") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "accepted"))
      $0.ok("POST /api/calls/call-1/heartbeat", CallFixtures.call(status: "accepted"))
    }
    rig.clock.advance(5)
    await rig.client.poll()
    rig.clock.advance(5)
    await rig.client.poll()
    rig.clock.advance(2)
    await rig.client.poll()
    #expect(
      Self.paths(rig) == [
        "POST /api/calls", "GET /api/calls/call-1", "POST /api/calls/call-1/heartbeat",
        "GET /api/calls/call-1"
      ])
    #expect(Self.body(try #require(rig.transport.requests.dropLast().last))["peer_id"] as? String == "alice")
  }

  private static func body(_ request: URLRequest) -> [String: Any] { LiveCallClientTests.body(request) }

  @Test("A ringing direct call is only read; a ringing group call already holds a lease and heartbeats")
  func heartbeatByKind() async throws {
    let direct = try await started("ringing") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "ringing"))
    }
    direct.clock.advance(30)
    await direct.client.poll()
    #expect(Self.paths(direct).last == "GET /api/calls/call-1")

    let group = try await started("accepted", conversation: Self.group, group: true) {
      $0.ok(
        "POST /api/calls/call-1/heartbeat",
        CallFixtures.call(
          status: "accepted", group: true, groupStatus: "accepted",
          participants: [("alice", "joined"), ("bob", "invited"), ("carol", "invited")]))
    }
    group.clock.advance(10)
    await group.client.poll()
    #expect(Self.paths(group).last == "POST /api/calls/call-1/heartbeat")
  }

  @Test("A ringing call becomes active when the other side answers, and an event is published")
  func refreshActivates() async throws {
    let rig = try await started("ringing") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "accepted"))
    }
    let stream = await rig.client.events()
    await rig.client.poll()
    #expect(await rig.client.currentCall?.state == .active)
    var iterator = stream.makeAsyncIterator()
    guard case .callUpdated(let updated)? = await iterator.next() else {
      Issue.record("no update")
      return
    }
    #expect(updated.state == .active)
    await rig.client.stopMonitoring()
  }

  @Test("A terminal state from the server ends the call, joins history and stops the heartbeat")
  func serverEnds() async throws {
    let rig = try await started("accepted") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "ended"))
    }
    rig.clock.advance(1)
    await rig.client.poll()
    #expect(await rig.client.currentCall?.state == .ended)
    #expect(await rig.client.history().map(\.state) == [.ended])
    rig.router.ok("GET /api/calls", CallFixtures.inbox())
    rig.clock.advance(30)
    await rig.client.poll()
    #expect(!Self.paths(rig).contains("POST /api/calls/call-1/heartbeat"))
    #expect(Self.paths(rig).last == "GET /api/calls")
  }

  // MARK: failures

  @Test("A transient failure never ends the call")
  func transientFailure() async throws {
    let rig = try await started("accepted") { $0.set("GET /api/calls/call-1", StubReply(503)) }
    rig.clock.advance(1)
    await rig.client.poll()
    #expect(await rig.client.currentCall?.state == .active)
    rig.router.set("GET /api/calls/call-1", StubReply(429))
    await rig.client.poll()
    #expect(await rig.client.currentCall?.state == .active)
  }

  @Test("404 ends the call locally; an attached state is used when present")
  func notFound() async throws {
    let gone = try await started("accepted") { $0.set("GET /api/calls/call-1", StubReply(404, Data("{}".utf8))) }
    gone.clock.advance(1)
    await gone.client.poll()
    #expect(await gone.client.currentCall?.state == .ended)

    let attached = CallFixtures.call(status: "ended")
    let withCall = try await started("accepted") {
      $0.set("GET /api/calls/call-1", StubReply(404, Data(#"{"error":"gone","call":\#(attached)}"#.utf8)))
    }
    withCall.clock.advance(1)
    await withCall.client.poll()
    #expect(await withCall.client.currentCall?.state == .ended)
  }

  @Test("403 ends the call locally; 401 reports the ended session")
  func forbiddenAndUnauthorized() async throws {
    let forbidden = try await started("accepted") { $0.set("GET /api/calls/call-1", StubReply(403)) }
    forbidden.clock.advance(1)
    await forbidden.client.poll()
    #expect(await forbidden.client.currentCall?.state == .ended)

    let unauthorized = try await started("accepted") { $0.set("GET /api/calls/call-1", StubReply(401)) }
    unauthorized.clock.advance(1)
    await unauthorized.client.poll()
    #expect(unauthorized.ended.count == 1)
    #expect(await unauthorized.client.currentCall?.state == .active)
  }

  @Test("A signed-out user polls nothing; stopMonitoring forgets the session")
  func signedOutAndStop() async throws {
    let signedOut = LiveCallClientTests.rig(user: nil)
    await signedOut.client.poll()
    #expect(signedOut.transport.requests.isEmpty)

    let rig = try await started("accepted")
    await rig.client.stopMonitoring()
    #expect(await rig.client.currentCall == nil)
    #expect(await rig.client.history().isEmpty)
  }
}
