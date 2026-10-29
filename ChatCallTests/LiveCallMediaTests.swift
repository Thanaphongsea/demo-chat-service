import Foundation
import Testing

@testable import ChatCall

@MainActor
struct LiveCallMediaTests {
  struct Rig {
    let client: LiveCallClient
    let router: Router
    let transport: StubTransport
    let factory: MediaFactory
  }

  private static let direct = try! LiveCallClientTests.conversation("c2c_bob", kind: .direct, members: ["alice", "bob"])
  private static let group = try! LiveCallClientTests.conversation("group_g1", kind: .group, members: ["alice", "bob", "carol"])

  private func rig(retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)], configure: (Router) -> Void = { _ in }) -> Rig {
    let router = Router()
    router.set("POST /api/rooms", StubReply(201, Data(#"{"room_id":"internal"}"#.utf8)))
    router.ok("GET /api/ice", #"{"iceServers":[{"urls":"stun:s.example.test"}]}"#)
    configure(router)
    let transport = StubTransport(reply: { router.reply(for: $0) })
    let api = VoIPClient(
      configuration: VoIPConfiguration(baseURL: URL(string: "https://voip.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let factory = MediaFactory()
    let media = MediaDependencies(
      makePeer: { _ in factory.makePeer() }, makeTransport: { factory.makeTransport() },
      sleep: { _ in }, retryDelays: retryDelays)
    let client = LiveCallClient(
      api: api, currentUser: { LiveCallClientTests.alice }, now: { Date(timeIntervalSince1970: 1_800_000_000) },
      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, media: media)
    return Rig(client: client, router: router, transport: transport, factory: factory)
  }

  private func startDirect(_ status: String, configure: (Router) -> Void = { _ in }) async throws -> Rig {
    let rig = rig {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: status).utf8)))
      configure($0)
    }
    _ = try await rig.client.startVideoCall(in: Self.direct)
    return rig
  }

  private func connected(_ rig: Rig) async throws {
    try #require(await waitUntil { (rig.factory.transport?.sent.count ?? 0) >= 2 })
  }

  private static let groupActive = CallFixtures.call(
    status: "accepted", group: true, groupStatus: "accepted",
    participants: [("alice", "joined"), ("bob", "invited"), ("carol", "invited")])

  @Test("An accepted direct call opens the room, fetches ICE and starts media")
  func startsOnAccepted() async throws {
    let rig = try await startDirect("accepted")
    try await connected(rig)
    let paths = LiveCallClientTests.paths(LiveCallClientTests.Rig(
      client: rig.client, router: rig.router, transport: rig.transport, clock: Clock(), ended: Tally(), keys: Tally()))
    #expect(paths.contains("POST /api/rooms") && paths.contains("GET /api/ice"))
    #expect(rig.factory.trace.all.first == "peer1.start(ice=1,mic=true,cam=true)")
    await rig.client.stopMonitoring()
  }

  @Test("A group creator is in the room at once, even while the screen still rings")
  func groupCreatorStartsWhileRinging() async throws {
    let rig = rig { $0.set("POST /api/calls", StubReply(201, Data(Self.groupActive.utf8))) }
    let call = try await rig.client.startVideoCall(in: Self.group)
    #expect(call.state == .ringing)
    try await connected(rig)
    await rig.client.stopMonitoring()
  }

  @Test("A ringing direct call starts media only after the other side accepts")
  func waitsForAccept() async throws {
    let rig = try await startDirect("ringing") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "ringing"))
    }
    await rig.client.poll()
    #expect(rig.factory.generations == 0)
    rig.router.ok("GET /api/calls/call-1", CallFixtures.call(status: "accepted"))
    await rig.client.poll()
    try await connected(rig)
    #expect(await rig.client.currentCall?.state == .active)
    await rig.client.stopMonitoring()
  }

  @Test("The media roster decides who is on screen, and observers are told")
  func rosterBecomesParticipants() async throws {
    let rig = try await startDirect("accepted") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "accepted"))
    }
    try await connected(rig)
    let stream = await rig.client.events()
    rig.factory.transport?.push(.roomPeers(["bob", "carol"]))
    try #require(await waitUntil { await rig.client.currentCall?.participants.map(\.id.rawValue) == ["alice", "bob", "carol"] })
    var iterator = stream.makeAsyncIterator()
    guard case .callUpdated(let updated)? = await iterator.next() else {
      Issue.record("no update")
      return
    }
    #expect(updated.participants.map(\.id.rawValue) == ["alice", "bob", "carol"])
    #expect(updated.localUserID == UserID("alice"))
    await rig.client.stopMonitoring()
  }

  @Test("A lost socket shows reconnecting and returns to active when media is back")
  func reconnectingState() async throws {
    let rig = try await startDirect("accepted") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "accepted"))
    }
    try await connected(rig)
    rig.factory.transport?.push(.answer(SessionDescription(type: "answer", sdp: "a")))
    try await Task.sleep(for: .milliseconds(30))
    rig.factory.transport?.drop()
    try #require(await waitUntil { await rig.client.currentCall?.state == .reconnecting })
    try #require(await waitUntil { rig.factory.generations == 2 })
    // A refresh from the server must not undo the reconnecting presentation.
    await rig.client.poll()
    #expect(await rig.client.currentCall?.state == .reconnecting)
    try #require(await waitUntil { (rig.factory.transport?.sent.count ?? 0) >= 2 })
    rig.factory.transport?.push(.answer(SessionDescription(type: "answer", sdp: "b")))
    try #require(await waitUntil { await rig.client.currentCall?.state == .active })
    await rig.client.stopMonitoring()
  }

  @Test("When recovery is exhausted the call ends locally")
  func failedMediaEndsCall() async throws {
    let rig = rig(retryDelays: []) {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "accepted").utf8)))
    }
    _ = try await rig.client.startVideoCall(in: Self.direct)
    try await connected(rig)
    rig.factory.transport?.drop()
    try #require(await waitUntil { await rig.client.currentCall?.state == .ended })
    #expect(await rig.client.history().map(\.state) == [.ended])
  }

  @Test("Leaving or ending stops the media")
  func endStopsMedia() async throws {
    let rig = rig {
      $0.set("POST /api/calls", StubReply(201, Data(Self.groupActive.utf8)))
      $0.ok(
        "POST /api/calls/call-1/leave",
        CallFixtures.call(
          status: "ended", group: true, groupStatus: "accepted", canJoin: true,
          participants: [("alice", "left"), ("bob", "joined")]))
    }
    _ = try await rig.client.startVideoCall(in: Self.group)
    try await connected(rig)
    _ = try await rig.client.end(callID: CallID("call-1"))
    try #require(await waitUntil { rig.factory.trace.all.contains("peer1.close") && rig.factory.trace.all.contains("socket1.close") })
  }

  @Test("A server that ends the call on refresh stops the media")
  func serverEndStopsMedia() async throws {
    let rig = try await startDirect("accepted") {
      $0.ok("GET /api/calls/call-1", CallFixtures.call(status: "ended"))
    }
    try await connected(rig)
    await rig.client.poll()
    try #require(await waitUntil { rig.factory.trace.all.contains("peer1.close") })
    #expect(await rig.client.currentCall?.state == .ended)
  }

  @Test("Local controls and visible-video requests reach the media layer")
  func controlsAndSubscriptions() async throws {
    let rig = try await startDirect("accepted")
    try await connected(rig)
    _ = try await rig.client.setMicrophoneEnabled(false, callID: CallID("call-1"))
    _ = try await rig.client.setCameraEnabled(false, callID: CallID("call-1"))
    _ = try await rig.client.setSpeakerEnabled(true, callID: CallID("call-1"))
    _ = try await rig.client.flipCamera(callID: CallID("call-1"))
    #expect(rig.factory.peer?.controls == ["mic=false", "cam=false", "speaker=true", "flip"])
    await rig.client.setVisibleVideoPeers([UserID("bob")], callID: CallID("call-1"))
    try #require(await waitUntil {
      rig.factory.transport?.sent.contains(.videoSubscriptions(["bob"])) == true
    })
    await rig.client.setVisibleVideoPeers([UserID("zed")], callID: CallID("other"))
    #expect(rig.factory.transport?.sent.contains(.videoSubscriptions(["zed"])) == false)
    await rig.client.stopMonitoring()
  }

  @Test("Without media dependencies the client stays signalling-only")
  func noMedia() async throws {
    let rig = LiveCallClientTests.rig {
      $0.set("POST /api/calls", StubReply(201, Data(CallFixtures.call(status: "accepted").utf8)))
    }
    _ = try await rig.client.startVideoCall(in: Self.direct)
    #expect(!LiveCallClientTests.paths(rig).contains("POST /api/rooms"))
  }
}
