import Foundation
import Testing

@testable import ChatCall

actor MediaEventCollector<Element: Sendable> {
  private(set) var items: [Element] = []
  private var task: Task<Void, Never>?
  func start(_ stream: AsyncStream<Element>) {
    task = Task { [weak self] in
      for await item in stream { await self?.add(item) }
    }
  }
  private func add(_ item: Element) { items.append(item) }
  func cancel() { task?.cancel() }
}

actor MediaSleeps {
  private(set) var values: [Duration] = []
  func record(_ d: Duration) { values.append(d) }
}

@MainActor
struct MediaSessionTests {
  static let me = UserID("alice")
  static let bob = UserID("bob")
  static let carol = UserID("carol")

  struct Rig {
    let session: MediaSession
    let factory: MediaFactory
    let router: Router
    let transport: StubTransport
    let events: MediaEventCollector<MediaEvent>
    let sleeps: MediaSleeps
  }

  private func rig(
    stillAccepted: @escaping @Sendable () async -> Bool = { true },
    configureRouter: (Router) -> Void = { _ in }, configure: (MediaFactory) -> Void = { _ in }
  ) async -> Rig {
    let router = Router()
    router.set("POST /api/rooms", StubReply(201, Data(#"{"room_id":"internal"}"#.utf8)))
    router.ok("GET /api/ice", #"{"iceServers":[{"urls":"stun:s.example.test"},{"urls":["turn:t.example.test"],"username":"u","credential":"c"}]}"#)
    configureRouter(router)
    let transport = StubTransport(reply: { router.reply(for: $0) })
    let api = VoIPClient(
      configuration: VoIPConfiguration(baseURL: URL(string: "https://voip.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let factory = MediaFactory()
    configure(factory)
    let sleeps = MediaSleeps()
    let session = MediaSession(
      api: api, makePeer: { factory.makePeer() }, makeTransport: { factory.makeTransport() },
      sleep: { await sleeps.record($0) }, stillAccepted: stillAccepted)
    let events = MediaEventCollector<MediaEvent>()
    await events.start(await session.events())
    return Rig(session: session, factory: factory, router: router, transport: transport, events: events, sleeps: sleeps)
  }

  private func begin(_ rig: Rig, microphone: Bool = true, camera: Bool = true) async {
    await rig.session.start(callID: "call-1", roomID: "grp_demo", me: Self.me, microphone: microphone, camera: camera)
  }

  private func sent(_ rig: Rig, generation: Int = 1) -> [SignalMessage] {
    rig.factory.transports.count >= generation ? rig.factory.transports[generation - 1].sent : []
  }

  private func connectedRig() async throws -> Rig {
    let rig = await rig()
    await begin(rig)
    try #require(await waitUntil { self.sent(rig).count >= 2 })
    return rig
  }

  private func answerNow(_ rig: Rig, generation: Int = 1) async throws {
    rig.factory.transports[generation - 1].push(.answer(SessionDescription(type: "answer", sdp: "a")))
    try #require(await waitUntil { rig.factory.trace.all.contains { $0.hasPrefix("peer\(generation).acceptAnswer") } })
  }

  // MARK: setup order

  @Test("Room, ICE, peer, socket, then subscriptions, then the initial offer, in that order")
  func setupOrder() async throws {
    let rig = await rig()
    await rig.session.setVisibleVideoPeers([Self.bob, Self.carol])
    await begin(rig)
    try #require(await waitUntil { self.sent(rig).count >= 2 })
    #expect(
      rig.transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        == ["POST /api/rooms", "GET /api/ice"])
    #expect(
      rig.factory.trace.all == [
        "peer1.start(ice=2,mic=true,cam=true)", "socket1.connect", "socket1.send(subs=bob,carol)",
        "peer1.createOffer", "socket1.send(offer offer-1)"
      ])
    let socket = try #require(rig.factory.transport)
    #expect(socket.connectedURL?.absoluteString == "wss://voip.example.test/api/ws?room_id=grp_demo&peer_id=alice&call_id=call-1")
    #expect(socket.connectedToken == "T")
    let events = await rig.events.items
    #expect(events.first == .state(.connecting))
    await rig.session.stop()
  }

  @Test("ICE that arrives before the answer is queued, then applied in order; later ICE applies at once")
  func iceQueue() async throws {
    let rig = try await connectedRig()
    let socket = try #require(rig.factory.transport)
    for text in ["c1", "c2"] { socket.push(.ice(IceCandidate(candidate: text, sdpMid: "0", sdpMLineIndex: 0))) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!rig.factory.trace.all.contains { $0.contains("remoteCandidate") })
    socket.push(.answer(SessionDescription(type: "answer", sdp: "a")))
    try #require(await waitUntil { rig.factory.trace.all.contains("peer1.remoteCandidate(c2)") })
    let order = rig.factory.trace.all.filter { $0.contains("acceptAnswer") || $0.contains("remoteCandidate") }
    #expect(order == ["peer1.acceptAnswer(a)", "peer1.remoteCandidate(c1)", "peer1.remoteCandidate(c2)"])
    socket.push(.ice(IceCandidate(candidate: "c3", sdpMid: "0", sdpMLineIndex: 0)))
    try #require(await waitUntil { rig.factory.trace.all.contains("peer1.remoteCandidate(c3)") })
    #expect(await rig.events.items.contains(.state(.connected)))
    await rig.session.stop()
  }

  @Test("Server offers are answered one at a time, in order")
  func serverOffersAreSerialized() async throws {
    let rig = await rig(configure: { $0.configurePeer = { $0.holdOffers = true } })
    await begin(rig)
    try #require(await waitUntil { self.sent(rig).count >= 2 })
    let socket = try #require(rig.factory.transport)
    socket.push(.offer(SessionDescription(type: "offer", sdp: "o1")))
    socket.push(.offer(SessionDescription(type: "offer", sdp: "o2")))
    try #require(await waitUntil { rig.factory.trace.all.contains("peer1.acceptOffer.begin(o1)") })
    try await Task.sleep(for: .milliseconds(60))
    #expect(!rig.factory.trace.all.contains("peer1.acceptOffer.begin(o2)"))
    rig.factory.peer?.releaseOffer()
    try #require(await waitUntil { rig.factory.trace.all.contains("peer1.acceptOffer.begin(o2)") })
    rig.factory.peer?.releaseOffer()
    try #require(await waitUntil { rig.factory.trace.all.contains("socket1.send(answer answer-to-o2)") })
    let order = rig.factory.trace.all.filter { $0.contains("acceptOffer") || $0.contains("send(answer") }
    #expect(
      order == [
        "peer1.acceptOffer.begin(o1)", "peer1.acceptOffer.end(o1)", "socket1.send(answer answer-to-o1)",
        "peer1.acceptOffer.begin(o2)", "peer1.acceptOffer.end(o2)", "socket1.send(answer answer-to-o2)"
      ])
    await rig.session.stop()
  }

  @Test("Local ICE candidates are sent to the server")
  func localCandidates() async throws {
    let rig = try await connectedRig()
    rig.factory.peer?.emitCandidate("lc1")
    try #require(await waitUntil { rig.factory.trace.all.contains("socket1.send(ice lc1)") })
    await rig.session.stop()
  }

  // MARK: roster and subscriptions

  @Test("Roster follows room_peers, peer_joined and peer_left; I am never listed; order is stable")
  func roster() async throws {
    let rig = try await connectedRig()
    let socket = try #require(rig.factory.transport)
    socket.push(.roomPeers(["carol", "alice", "bob"]))
    socket.push(.peerJoined("dave"))
    socket.push(.peerLeft("carol"))
    try #require(await waitUntil { await rig.events.items.filter { if case .roster = $0 { true } else { false } }.count == 3 })
    let rosters = await rig.events.items.compactMap { event -> [UserID]? in
      if case .roster(let ids) = event { ids } else { nil }
    }
    #expect(rosters == [[Self.bob, Self.carol], [Self.bob, Self.carol, UserID("dave")], [Self.bob, UserID("dave")]])
    await rig.session.stop()
  }

  @Test("Subscriptions are sent only when the visible set changes")
  func subscriptionsOnChange() async throws {
    let rig = try await connectedRig()
    func subscriptions() -> [[String]?] {
      sent(rig).compactMap { if case .videoSubscriptions(let ids) = $0 { ids } else { nil } }
    }
    #expect(subscriptions().count == 1 && subscriptions()[0] == [])
    await rig.session.setVisibleVideoPeers([Self.bob])
    await rig.session.setVisibleVideoPeers([Self.bob])
    await rig.session.setVisibleVideoPeers([Self.bob, Self.carol])
    #expect(subscriptions().map { $0 ?? ["all"] } == [[], ["bob"], ["bob", "carol"]])
    await rig.session.stop()
  }

  // MARK: recovery

  @Test("A dropped socket recovers on a new generation, re-sends subscriptions, and closes the old one")
  func recovery() async throws {
    let rig = try await connectedRig()
    await rig.session.setVisibleVideoPeers([Self.bob])
    try await answerNow(rig)
    rig.factory.transport?.drop()
    try #require(await waitUntil { rig.factory.generations == 2 && self.sent(rig, generation: 2).count >= 2 })
    #expect(await rig.sleeps.values == [.seconds(1)])
    let second = sent(rig, generation: 2)
    #expect(second[0] == .videoSubscriptions(["bob"]))
    #expect(second[1] == .offer(SessionDescription(type: "offer", sdp: "offer-2")))
    #expect(rig.factory.trace.all.contains("socket1.close") && rig.factory.trace.all.contains("peer1.close"))
    #expect(await rig.events.items.contains(.state(.reconnecting(attempt: 1))))
    // A successful answer resets the attempt counter.
    try await answerNow(rig, generation: 2)
    rig.factory.transport?.drop()
    try #require(await waitUntil { rig.factory.generations == 3 })
    #expect(await rig.events.items.filter { $0 == .state(.reconnecting(attempt: 1)) }.count == 2)
    await rig.session.stop()
  }

  @Test("Recovery stops when the server no longer has this device in the call")
  func recoveryChecksCallState() async throws {
    let rig = await rig(stillAccepted: { false })
    await begin(rig)
    try #require(await waitUntil { self.sent(rig).count >= 2 })
    rig.factory.transport?.drop()
    try #require(await waitUntil { await rig.events.items.contains(.state(.failed("the call is no longer active for this device"))) })
    #expect(rig.factory.generations == 1)
  }

  @Test("Three failed recoveries give up after delays of 1, 2 and 3 seconds")
  func boundedRecovery() async throws {
    let rig = await rig(configure: { $0.configureTransport = { $0.failConnect = true } })
    await begin(rig)
    try #require(await waitUntil { await rig.events.items.contains(.state(.failed("the media connection could not be recovered"))) })
    #expect(rig.factory.generations == 4)
    #expect(await rig.sleeps.values == [.seconds(1), .seconds(2), .seconds(3)])
  }

  @Test("A forbidden or missing call is fatal at once: no retry")
  func fatalSetup() async throws {
    let rig = await rig(configureRouter: { $0.set("POST /api/rooms", StubReply(403)) })
    await begin(rig)
    try #require(await waitUntil { await rig.events.items.contains(.state(.failed("media is not available for this call"))) })
    #expect(rig.factory.generations == 0)
    #expect(await rig.sleeps.values.isEmpty)
  }

  // MARK: controls and stop

  @Test("Local controls reach the peer and are remembered for the next generation")
  func controls() async throws {
    let rig = try await connectedRig()
    await rig.session.setMicrophone(false)
    await rig.session.setCamera(false)
    await rig.session.setSpeaker(true)
    await rig.session.flipCamera()
    #expect(rig.factory.peer?.controls == ["mic=false", "cam=false", "speaker=true", "flip"])
    rig.factory.transport?.drop()
    try #require(await waitUntil { rig.factory.generations == 2 })
    try #require(await waitUntil { rig.factory.trace.all.contains("peer2.start(ice=2,mic=false,cam=false)") })
    await rig.session.stop()
  }

  @Test("Stopping closes the socket and peer, ends the event stream, and starts nothing new")
  func stopCleansUp() async throws {
    let rig = try await connectedRig()
    await rig.session.stop()
    #expect(rig.factory.trace.all.contains("socket1.close") && rig.factory.trace.all.contains("peer1.close"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.factory.generations == 1)
    #expect(await rig.sleeps.values.isEmpty)
  }
}
