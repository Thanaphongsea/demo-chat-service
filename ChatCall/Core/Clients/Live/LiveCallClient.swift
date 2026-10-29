import Foundation

/// How a live call gets its audio and video. Nil means signalling only (no media).
nonisolated struct MediaDependencies: Sendable {
  let makePeer: @Sendable (UserID) -> any MediaPeer
  let makeTransport: @Sendable () -> any SignalingTransport
  let sleep: @Sendable (Duration) async -> Void
  let retryDelays: [Duration]

  init(
    makePeer: @escaping @Sendable (UserID) -> any MediaPeer,
    makeTransport: @escaping @Sendable () -> any SignalingTransport,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]
  ) {
    self.makePeer = makePeer
    self.makeTransport = makeTransport
    self.sleep = sleep
    self.retryDelays = retryDelays
  }

  /// WebRTC over an authenticated URLSession WebSocket.
  static let live = MediaDependencies(
    makePeer: { WebRTCPeer(userID: $0) }, makeTransport: { URLSessionSignalingTransport() })
}

/// Calls over the VoIP REST API: create, answer, decline, join, leave and end, plus polling for incoming
/// and joinable calls and a heartbeat for the viewer's lease. No audio or video yet.
actor LiveCallClient: CallClient {
  static let maxInvitees = CallMapper.maxPeople - 1

  private let api: VoIPClient
  private let currentUser: @Sendable () async -> User?
  private let now: @Sendable () -> Date
  private let makeKey: @Sendable () -> String
  private let sleep: @Sendable (Duration) async -> Void
  private let pollInterval: Duration
  private let heartbeatInterval: TimeInterval
  private let onSessionEnded: @Sendable () async -> Void
  private let media: MediaDependencies?

  private var current: CallSnapshot?
  private var completed: [CallSnapshot] = []
  private var joinable: [CallSnapshot] = []
  /// Calls this session already acted on; a stale inbox must never bring them back as incoming.
  private var handled: Set<CallID> = []
  private var lastHeartbeat: Date?
  private var pendingCreate: CreateCallRequest?
  private var controls = Controls()
  private var observers: [UUID: AsyncStream<CallEvent>.Continuation] = [:]
  private var monitor: Task<Void, Never>?
  private var session: MediaSession?
  private var mediaCallID: CallID?
  private var mediaTask: Task<Void, Never>?
  private var mediaReconnecting = false
  private var mediaRoster: [UserID]?
  private var visibleVideo: [UserID] = []

  private struct Controls {
    var microphone = true
    var camera = true
    var speaker = true
    var position = CameraPosition.front
  }

  init(
    api: VoIPClient, currentUser: @escaping @Sendable () async -> User?,
    now: @escaping @Sendable () -> Date = { Date() },
    makeKey: @escaping @Sendable () -> String = { "ios-call-\(UUID().uuidString.lowercased())" },
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    pollInterval: Duration = .seconds(1), heartbeatInterval: TimeInterval = 10,
    onSessionEnded: @escaping @Sendable () async -> Void = {}, media: MediaDependencies? = nil
  ) {
    self.api = api
    self.currentUser = currentUser
    self.now = now
    self.makeKey = makeKey
    self.sleep = sleep
    self.pollInterval = pollInterval
    self.heartbeatInterval = heartbeatInterval
    self.onSessionEnded = onSessionEnded
    self.media = media
  }

  // MARK: CallClient

  var currentCall: CallSnapshot? { current }

  func history() async -> [CallSnapshot] {
    var byID: [CallID: CallSnapshot] = [:]
    for call in completed { byID[call.id] = call }
    for call in joinable { byID[call.id] = call }
    return byID.values.sorted { $0.startedAt > $1.startedAt }
  }

  func startVideoCall(in conversation: Conversation) async throws -> CallSnapshot {
    let me = try await requireUser()
    guard current == nil || current?.state.isTerminal == true else {
      throw CallError.callAlreadyInProgress
    }
    guard conversation.memberIDs.contains(me.id),
      let room = CallMapper.roomID(for: conversation.id, me: me.id)
    else { throw CallError.invalidConversation }
    var seen: Set<UserID> = [me.id]
    let others = conversation.memberIDs.filter { seen.insert($0).inserted }
    guard !others.isEmpty else { throw CallError.invalidConversation }
    guard others.count <= Self.maxInvitees else {
      throw CallError.capacityExceeded(maximum: CallMapper.maxPeople)
    }
    let isGroup = conversation.kind == .group
    var request = CreateCallRequest(
      callerID: me.id.rawValue, callerName: me.displayName, roomID: room,
      calleeID: isGroup ? nil : others[0].rawValue,
      calleeIDs: isGroup ? others.map(\.rawValue) : nil, idempotencyKey: makeKey())
    // A retry after a timeout must reuse the first attempt's key, or the server may create a second call.
    if let pending = pendingCreate, Self.samePayload(pending, request) {
      request = pending
    }
    pendingCreate = request
    do {
      let wire = try await api.create(request)
      pendingCreate = nil
      handled.insert(CallID(wire.callID))
      return try await commit(wire, me: me.id)
    } catch {
      if !Self.isRetryable(error) { pendingCreate = nil }
      throw await translate(error, creating: true)
    }
  }

  func answer(callID: CallID) async throws -> CallSnapshot {
    try await act(.accept, on: callID, allowed: [.incoming])
  }

  func decline(callID: CallID) async throws -> CallSnapshot {
    try await act(.reject, on: callID, allowed: [.incoming])
  }

  func end(callID: CallID) async throws -> CallSnapshot {
    guard let call = current, call.id == callID else { throw CallError.callNotFound }
    guard !call.state.isTerminal, call.state != .incoming else { throw CallError.invalidTransition }
    let action: CallAction
    if call.kind == .group {
      action = .leave
    } else if call.state == .ringing {
      action = call.direction == .outgoing ? .cancel : .reject
    } else {
      action = .end
    }
    return try await act(action, on: callID, allowed: [.ringing, .active, .reconnecting])
  }

  func endForEveryone(callID: CallID) async throws -> CallSnapshot {
    guard let call = current, call.kind == .group, call.direction == .outgoing else {
      throw CallError.invalidTransition
    }
    return try await act(.endAll, on: callID, allowed: [.ringing, .active, .reconnecting])
  }

  func join(callID: CallID) async throws -> CallSnapshot {
    guard current == nil || current?.state.isTerminal == true else {
      throw CallError.callAlreadyInProgress
    }
    let me = try await requireUser()
    do {
      let wire = try await api.perform(.join, id: callID.rawValue, peer: me.id)
      handled.insert(callID)
      return try await commit(wire, me: me.id)
    } catch {
      throw await translate(error, creating: false)
    }
  }

  func setVisibleVideoPeers(_ users: [UserID], callID: CallID) async {
    visibleVideo = users
    guard mediaCallID == callID else { return }
    await session?.setVisibleVideoPeers(users)
  }

  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    controls.microphone = enabled
    let updated = try updateControls(callID)
    await session?.setMicrophone(enabled)
    return updated
  }

  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    controls.camera = enabled
    let updated = try updateControls(callID)
    await session?.setCamera(enabled)
    return updated
  }

  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    controls.speaker = enabled
    let updated = try updateControls(callID)
    await session?.setSpeaker(enabled)
    return updated
  }

  func flipCamera(callID: CallID) async throws -> CallSnapshot {
    controls.position = controls.position == .front ? .back : .front
    let updated = try updateControls(callID)
    await session?.flipCamera()
    return updated
  }

  func demoIncomingCall(kind: CallKind) async throws -> CallSnapshot { throw CallError.unsupported }
  func demoMissedCall(kind: CallKind) async throws -> CallSnapshot { throw CallError.unsupported }
  func demoReconnect(callID: CallID) async throws -> CallSnapshot { throw CallError.unsupported }

  func events() async -> AsyncStream<CallEvent> {
    let (stream, continuation) = AsyncStream<CallEvent>.makeStream()
    let id = UUID()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    if monitor == nil { startMonitoring() }
    return stream
  }

  /// Stops polling and heartbeats, e.g. on sign-out.
  func stopMonitoring() async {
    await stopMedia()
    monitor?.cancel()
    monitor = nil
    for observer in observers.values { observer.finish() }
    observers = [:]
    current = nil
    completed = []
    joinable = []
    handled = []
    lastHeartbeat = nil
    pendingCreate = nil
  }

  // MARK: polling and heartbeat

  /// One monitoring cycle: renew the lease or refresh the live call, else look for incoming and joinable calls.
  func poll() async {
    guard let me = await currentUser() else { return }
    do {
      if let call = current, !call.state.isTerminal {
        try await refresh(call, me: me.id)
      } else {
        try await discover(me: me.id)
      }
    } catch is CancellationError {
      return
    } catch {
      await handlePollFailure(error, me: me.id)
    }
  }

  private func map(_ wire: WireCallInfo, me: UserID) -> CallSnapshot? {
    guard
      let snapshot = CallMapper.snapshot(
        wire, me: me, microphone: controls.microphone, camera: controls.camera,
        speaker: controls.speaker, cameraPosition: controls.position)
    else { return nil }
    guard mediaCallID == snapshot.id, !snapshot.state.isTerminal else { return snapshot }
    // While media runs, the room roster is the truth for who is on screen and for recovery state.
    let state: CallState = mediaReconnecting && snapshot.state == .active ? .reconnecting : snapshot.state
    let people = mediaRoster.map { Self.people($0, existing: snapshot.participants, me: me) }
    return Self.replacing(snapshot, state: state, participants: people ?? snapshot.participants)
  }

  private func startMonitoring() {
    monitor = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.poll()
        await self.sleep(self.pollInterval)
      }
    }
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
    if observers.isEmpty {
      monitor?.cancel()
      monitor = nil
    }
  }

  private func refresh(_ call: CallSnapshot, me: UserID) async throws {
    let heartbeatDue =
      (call.state == .active || call.state == .reconnecting
        || (call.state == .ringing && call.kind == .group))
      && now().timeIntervalSince(lastHeartbeat ?? .distantPast) >= heartbeatInterval
    let wire: WireCallInfo
    if heartbeatDue {
      lastHeartbeat = now()
      wire = try await api.perform(.heartbeat, id: call.id.rawValue, peer: me)
    } else {
      wire = try await api.call(id: call.id.rawValue, peer: me)
    }
    guard current?.id == call.id, current?.state.isTerminal == false else { return }
    try await commit(wire, me: me)
  }

  private func discover(me: UserID) async throws {
    let inbox = try await api.inbox(peer: me)
    // Actions may have run while the request was in flight; a stale inbox must not undo them.
    guard current == nil || current?.state.isTerminal == true else { return }
    joinable = inbox.joinableCalls.compactMap { map($0, me: me) }
      .filter(\.canJoin)
    if let ringing = inbox.calls.first(where: { !handled.contains(CallID($0.callID)) }),
      let snapshot = map(ringing, me: me),
      snapshot.state == .incoming
    {
      lastHeartbeat = nil
      current = snapshot
      emit(snapshot)
    }
  }

  private func handlePollFailure(_ error: Error, me: UserID) async {
    switch error as? VoIPError {
    case .notFound(let call), .conflict(let call, _):
      if let call, (try? await commit(call, me: me)) != nil { return }
      if case .notFound = error as? VoIPError { await endLocally() }
    case .forbidden:
      await endLocally()
    case .unauthorized, .revoked:
      await onSessionEnded()
    default:
      callLog.notice("poll failed; will retry")  // transient failures never end a call
    }
  }

  private func endLocally() async {
    guard let call = current, !call.state.isTerminal else { return }
    await stopMedia()
    store(Self.replacing(call, state: .ended, canJoin: false))
  }

  // MARK: state

  private func act(_ action: CallAction, on callID: CallID, allowed: [CallState]) async throws
    -> CallSnapshot
  {
    guard let call = current, call.id == callID else { throw CallError.callNotFound }
    guard allowed.contains(call.state) else { throw CallError.invalidTransition }
    let me = try await requireUser()
    do {
      let wire = try await api.perform(action, id: callID.rawValue, peer: me.id)
      handled.insert(callID)
      return try await commit(wire, me: me.id)
    } catch {
      throw await translate(error, creating: false)
    }
  }

  private func updateControls(_ callID: CallID) throws -> CallSnapshot {
    guard let call = current, call.id == callID else { throw CallError.callNotFound }
    guard !call.state.isTerminal, call.state != .incoming else { throw CallError.invalidTransition }
    let updated = Self.replacing(
      call, microphone: controls.microphone, camera: controls.camera, speaker: controls.speaker,
      position: controls.position)
    store(updated)
    return updated
  }

  @discardableResult
  private func commit(_ wire: WireCallInfo, me: UserID) async throws -> CallSnapshot {
    guard let snapshot = map(wire, me: me) else {
      throw VoIPError.invalidResponse
    }
    if snapshot.state == .active || snapshot.state == .ringing, lastHeartbeat == nil {
      lastHeartbeat = now()
    }
    store(snapshot)
    await syncMedia(wire, me: me)
    return snapshot
  }

  private func store(_ snapshot: CallSnapshot) {
    guard snapshot != current else { return }
    current = snapshot
    if snapshot.state.isTerminal {
      lastHeartbeat = nil
      completed.removeAll { $0.id == snapshot.id }
      completed.append(snapshot)
      if snapshot.canJoin {
        joinable.removeAll { $0.id == snapshot.id }
        joinable.append(snapshot)
      } else {
        joinable.removeAll { $0.id == snapshot.id }
      }
    } else {
      joinable.removeAll { $0.id == snapshot.id }
    }
    emit(snapshot)
  }

  private func emit(_ snapshot: CallSnapshot) {
    for observer in observers.values { observer.yield(.callUpdated(snapshot)) }
  }

  private func requireUser() async throws -> User {
    guard let user = await currentUser() else { throw VoIPError.unauthorized }
    return user
  }

  private func translate(_ error: Error, creating: Bool) async -> Error {
    switch error as? VoIPError {
    case .conflict: return creating ? CallError.callAlreadyInProgress : CallError.invalidTransition
    case .notFound: return CallError.callNotFound
    case .unauthorized, .revoked:
      await onSessionEnded()
      return error
    default: return error
    }
  }

  // MARK: media

  private func syncMedia(_ wire: WireCallInfo, me: UserID) async {
    guard let media else { return }
    let id = CallID(wire.callID)
    // Media runs while the server has this device accepted in a call that is still running.
    let inRoom = wire.status == "accepted" && wire.groupStatus != "ended"
    if inRoom {
      guard mediaCallID != id else { return }
      await stopMedia()
      await startMedia(id, roomID: wire.roomID, me: me, media: media)
    } else if mediaCallID == id {
      await stopMedia()
    }
  }

  private func startMedia(_ id: CallID, roomID: String, me: UserID, media: MediaDependencies) async {
    let api = api
    let session = MediaSession(
      api: api, makePeer: { media.makePeer(me) }, makeTransport: media.makeTransport,
      sleep: media.sleep, stillAccepted: { [weak self] in await self?.serverKeepsMe(in: id) ?? false },
      retryDelays: media.retryDelays)
    self.session = session
    mediaCallID = id
    mediaReconnecting = false
    mediaRoster = nil
    let stream = await session.events()
    mediaTask = Task { [weak self] in
      for await event in stream { await self?.handleMedia(event, callID: id, me: me) }
    }
    await session.setVisibleVideoPeers(visibleVideo)
    await session.start(
      callID: id.rawValue, roomID: roomID, me: me, microphone: controls.microphone,
      camera: controls.camera)
  }

  private func stopMedia() async {
    mediaTask?.cancel()
    mediaTask = nil
    let old = session
    session = nil
    mediaCallID = nil
    mediaReconnecting = false
    mediaRoster = nil
    await old?.stop()
  }

  private func handleMedia(_ event: MediaEvent, callID: CallID, me: UserID) async {
    guard mediaCallID == callID, let call = current, call.id == callID, !call.state.isTerminal
    else { return }
    switch event {
    case .roster(let users):
      mediaRoster = users
      store(Self.replacing(call, participants: Self.people(users, existing: call.participants, me: me)))
    case .state(.reconnecting):
      mediaReconnecting = true
      if call.state == .active { store(Self.replacing(call, state: .reconnecting)) }
    case .state(.connected):
      mediaReconnecting = false
      if call.state == .reconnecting { store(Self.replacing(call, state: .active)) }
    case .state(.failed):
      await endLocally()
    case .state(.connecting):
      break
    }
  }

  /// Recovery applies only while the server still holds this device in the call; a definitive "no" ends it.
  private func serverKeepsMe(in id: CallID) async -> Bool {
    guard let me = await currentUser() else { return false }
    do {
      let wire = try await api.call(id: id.rawValue, peer: me.id)
      return wire.status == "accepted" && wire.groupStatus != "ended"
    } catch VoIPError.notFound, VoIPError.forbidden {
      return false
    } catch {
      return true  // a transient failure must not abandon a call that may still be there
    }
  }

  private static func people(_ roster: [UserID], existing: [User], me: UserID) -> [User] {
    let known = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let localUser = known[me] ?? User(id: me, displayName: me.rawValue, initials: String(me.rawValue.prefix(2)).uppercased())
    return [localUser]
      + roster.filter { $0 != me }.map {
        known[$0] ?? User(id: $0, displayName: $0.rawValue, initials: String($0.rawValue.prefix(2)).uppercased())
      }
  }

  private static func replacing(
    _ call: CallSnapshot, state: CallState? = nil, participants: [User]? = nil,
    microphone: Bool? = nil, camera: Bool? = nil, speaker: Bool? = nil,
    position: CameraPosition? = nil, canJoin: Bool? = nil
  ) -> CallSnapshot {
    CallSnapshot(
      id: call.id, conversationID: call.conversationID, kind: call.kind, direction: call.direction,
      state: state ?? call.state, participants: participants ?? call.participants,
      startedAt: call.startedAt, microphoneEnabled: microphone ?? call.microphoneEnabled,
      cameraEnabled: camera ?? call.cameraEnabled, speakerEnabled: speaker ?? call.speakerEnabled,
      cameraPosition: position ?? call.cameraPosition, canJoin: canJoin ?? call.canJoin,
      localUserID: call.localUserID)
  }

  private static func samePayload(_ a: CreateCallRequest, _ b: CreateCallRequest) -> Bool {
    a.callerID == b.callerID && a.roomID == b.roomID && a.calleeID == b.calleeID
      && a.calleeIDs == b.calleeIDs
  }

  private static func isRetryable(_ error: Error) -> Bool {
    switch error as? VoIPError {
    case .transport, .server, .rateLimited: true
    default: error is CancellationError
    }
  }
}
