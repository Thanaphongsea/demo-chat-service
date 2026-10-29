import Foundation

/// The platform side of a call's media: one peer connection plus its local capture. The WebRTC
/// implementation lives behind this so the signalling logic can be tested without a network.
nonisolated protocol MediaPeer: Sendable {
  func start(iceServers: [WireICEServer], microphone: Bool, camera: Bool) async throws
  /// Creates the initial offer and sets it as the local description.
  func createOffer() async throws -> SessionDescription
  /// Applies the server's answer to our offer.
  func acceptAnswer(_ answer: SessionDescription) async throws
  /// Applies a server offer and returns the answer that was set locally.
  func acceptOffer(_ offer: SessionDescription) async throws -> SessionDescription
  func addRemoteCandidate(_ candidate: IceCandidate) async throws
  var localCandidates: AsyncStream<IceCandidate> { get }
  func setMicrophone(_ enabled: Bool) async
  func setCamera(_ enabled: Bool) async
  func setSpeaker(_ enabled: Bool) async
  func flipCamera() async
  func close() async
}

nonisolated enum MediaState: Equatable, Sendable {
  case connecting
  case connected
  case reconnecting(attempt: Int)
  /// Recovery is over; the caller decides whether the call ends.
  case failed(String)
}

nonisolated enum MediaEvent: Equatable, Sendable {
  case state(MediaState)
  /// The other people in the room, sorted so tile order is stable.
  case roster([UserID])
}

/// Runs the media signalling for one call: room, ICE, authenticated socket, subscriptions before the
/// initial offer, serialized SDP exchange, queued ICE, roster, and bounded generation-guarded recovery.
actor MediaSession {
  private let api: VoIPClient
  private let makePeer: @Sendable () -> any MediaPeer
  private let makeTransport: @Sendable () -> any SignalingTransport
  private let sleep: @Sendable (Duration) async -> Void
  private let stillAccepted: @Sendable () async -> Bool
  private let retryDelays: [Duration]

  private var generation = 0
  private var runner: Task<Void, Never>?
  private var peer: (any MediaPeer)?
  private var transport: (any SignalingTransport)?
  private var observers: [UUID: AsyncStream<MediaEvent>.Continuation] = [:]
  private var visible: [UserID] = []
  private var lastSentVisible: [UserID]?
  private var microphone = true
  private var camera = true
  private var me = UserID("")
  private var roster: Set<String> = []

  init(
    api: VoIPClient, makePeer: @escaping @Sendable () -> any MediaPeer,
    makeTransport: @escaping @Sendable () -> any SignalingTransport,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    stillAccepted: @escaping @Sendable () async -> Bool = { true },
    retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]
  ) {
    self.api = api
    self.makePeer = makePeer
    self.makeTransport = makeTransport
    self.sleep = sleep
    self.stillAccepted = stillAccepted
    self.retryDelays = retryDelays
  }

  func events() -> AsyncStream<MediaEvent> {
    let (stream, continuation) = AsyncStream<MediaEvent>.makeStream()
    let id = UUID()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  func start(
    callID: String, roomID: String, me: UserID, microphone: Bool = true, camera: Bool = true
  ) {
    stopRunning()
    generation += 1
    let current = generation
    self.me = me
    self.microphone = microphone
    self.camera = camera
    roster = []
    lastSentVisible = nil
    runner = Task { [weak self] in
      await self?.run(generation: current, callID: callID, roomID: roomID)
    }
  }

  func stop() async {
    generation += 1
    let old = (peer, transport)
    stopRunning()
    await old.1?.close()
    await old.0?.close()
    for observer in observers.values { observer.finish() }
    observers = [:]
  }

  /// The users whose video to receive (the current page's remotes). Audio always flows for everyone.
  func setVisibleVideoPeers(_ ids: [UserID]) async {
    visible = ids
    await sendSubscriptionsIfChanged()
  }

  func setMicrophone(_ enabled: Bool) async {
    microphone = enabled
    await peer?.setMicrophone(enabled)
  }

  func setCamera(_ enabled: Bool) async {
    camera = enabled
    await peer?.setCamera(enabled)
  }

  func setSpeaker(_ enabled: Bool) async { await peer?.setSpeaker(enabled) }
  func flipCamera() async { await peer?.flipCamera() }

  // MARK: run loop

  private func run(generation g: Int, callID: String, roomID: String) async {
    var attempt = 0
    while !Task.isCancelled, g == generation {
      emit(.state(attempt == 0 ? .connecting : .reconnecting(attempt: attempt)))
      do {
        try await connect(generation: g, callID: callID, roomID: roomID, attempt: &attempt)
      } catch is CancellationError {
        return
      } catch let error as VoIPError where Self.isFatal(error) {
        guard g == generation else { return }
        await teardown(generation: g)
        emit(.state(.failed("media is not available for this call")))
        return
      } catch {
        callLog.notice("media connection lost: \(String(describing: type(of: error)), privacy: .public)")
      }
      guard g == generation, !Task.isCancelled else { return }
      await teardown(generation: g)
      guard attempt < retryDelays.count else {
        emit(.state(.failed("the media connection could not be recovered")))
        return
      }
      await sleep(retryDelays[attempt])
      attempt += 1
      guard g == generation, !Task.isCancelled else { return }
      // Recovery only applies while the server still has us in the call; otherwise the user must Rejoin.
      guard await stillAccepted() else {
        emit(.state(.failed("the call is no longer active for this device")))
        return
      }
    }
  }

  /// One generation of media. Returns when the socket closes; throws when setup or the socket fails.
  private func connect(generation g: Int, callID: String, roomID: String, attempt: inout Int)
    async throws
  {
    try await api.prepareRoom(callID: callID, roomID: roomID)
    let ice = try await api.iceServers()
    let socket = try await api.mediaSocket(roomID: roomID, callID: callID, peer: me)
    guard g == generation else { throw CancellationError() }

    let peer = makePeer()
    let transport = makeTransport()
    self.peer = peer
    self.transport = transport
    try await peer.start(iceServers: ice, microphone: microphone, camera: camera)
    try await transport.connect(url: socket.url, token: socket.token)
    guard g == generation else { throw CancellationError() }

    // Subscriptions go out before the initial offer so a phone never receives every video.
    lastSentVisible = nil
    await sendSubscriptionsIfChanged()
    try await transport.send(.offer(try await peer.createOffer()))

    let forwarder = Task { [weak self] in
      for await candidate in peer.localCandidates {
        guard let self, await self.isCurrent(g) else { return }
        try? await transport.send(.ice(candidate))
      }
    }
    defer { forwarder.cancel() }

    var remoteReady = false
    var queued: [IceCandidate] = []
    for try await message in transport.messages {
      guard g == generation else { return }
      switch message {
      case .answer(let answer):
        try await peer.acceptAnswer(answer)
        remoteReady = true
        attempt = 0
        emit(.state(.connected))
        for candidate in queued { try await peer.addRemoteCandidate(candidate) }
        queued = []
      case .offer(let offer):
        let answer = try await peer.acceptOffer(offer)
        try await transport.send(.answer(answer))
        remoteReady = true
        for candidate in queued { try await peer.addRemoteCandidate(candidate) }
        queued = []
      case .ice(let candidate):
        if remoteReady {
          try await peer.addRemoteCandidate(candidate)
        } else {
          queued.append(candidate)
        }
      case .roomPeers(let peers):
        roster = Set(peers)
        publishRoster()
      case .peerJoined(let user):
        roster.insert(user)
        publishRoster()
      case .peerLeft(let user):
        roster.remove(user)
        publishRoster()
      case .error(let text):
        callLog.error("media server error: \(text.isEmpty ? "unspecified" : "reported", privacy: .public)")
      case .videoSubscriptions, .unknown:
        break
      }
    }
  }

  private func teardown(generation g: Int) async {
    guard g == generation else { return }
    let old = (peer, transport)
    peer = nil
    transport = nil
    lastSentVisible = nil
    await old.1?.close()
    await old.0?.close()
  }

  // MARK: helpers

  private func stopRunning() {
    runner?.cancel()
    runner = nil
    peer = nil
    transport = nil
  }

  private func isCurrent(_ g: Int) -> Bool { g == generation }

  private func sendSubscriptionsIfChanged() async {
    guard let transport, lastSentVisible != visible else { return }
    lastSentVisible = visible
    try? await transport.send(.videoSubscriptions(visible.map(\.rawValue)))
  }

  private func publishRoster() {
    emit(.roster(roster.filter { $0 != me.rawValue }.sorted().map { UserID($0) }))
  }

  private func emit(_ event: MediaEvent) {
    for observer in observers.values { observer.yield(event) }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

  private static func isFatal(_ error: VoIPError) -> Bool {
    switch error {
    case .forbidden, .notFound, .unauthorized, .revoked, .badRequest, .conflict: true
    default: false
    }
  }
}
