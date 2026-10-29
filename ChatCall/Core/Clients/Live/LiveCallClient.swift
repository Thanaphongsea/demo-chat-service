import Foundation

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
    onSessionEnded: @escaping @Sendable () async -> Void = {}
  ) {
    self.api = api
    self.currentUser = currentUser
    self.now = now
    self.makeKey = makeKey
    self.sleep = sleep
    self.pollInterval = pollInterval
    self.heartbeatInterval = heartbeatInterval
    self.onSessionEnded = onSessionEnded
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
      return try commit(wire, me: me.id)
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
      return try commit(wire, me: me.id)
    } catch {
      throw await translate(error, creating: false)
    }
  }

  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    controls.microphone = enabled
    return try updateControls(callID)
  }

  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    controls.camera = enabled
    return try updateControls(callID)
  }

  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    controls.speaker = enabled
    return try updateControls(callID)
  }

  func flipCamera(callID: CallID) async throws -> CallSnapshot {
    controls.position = controls.position == .front ? .back : .front
    return try updateControls(callID)
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
  func stopMonitoring() {
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
    CallMapper.snapshot(
      wire, me: me, microphone: controls.microphone, camera: controls.camera,
      speaker: controls.speaker, cameraPosition: controls.position)
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
      (call.state == .active || (call.state == .ringing && call.kind == .group))
      && now().timeIntervalSince(lastHeartbeat ?? .distantPast) >= heartbeatInterval
    let wire: WireCallInfo
    if heartbeatDue {
      lastHeartbeat = now()
      wire = try await api.perform(.heartbeat, id: call.id.rawValue, peer: me)
    } else {
      wire = try await api.call(id: call.id.rawValue, peer: me)
    }
    guard current?.id == call.id, current?.state.isTerminal == false else { return }
    try commit(wire, me: me)
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
      if let call, (try? commit(call, me: me)) != nil { return }
      if case .notFound = error as? VoIPError { endLocally() }
    case .forbidden:
      endLocally()
    case .unauthorized, .revoked:
      await onSessionEnded()
    default:
      callLog.notice("poll failed; will retry")  // transient failures never end a call
    }
  }

  private func endLocally() {
    guard let call = current, !call.state.isTerminal else { return }
    let ended = CallSnapshot(
      id: call.id, conversationID: call.conversationID, kind: call.kind, direction: call.direction,
      state: .ended, participants: call.participants, startedAt: call.startedAt,
      microphoneEnabled: call.microphoneEnabled, cameraEnabled: call.cameraEnabled,
      speakerEnabled: call.speakerEnabled, cameraPosition: call.cameraPosition,
      canJoin: false, localUserID: call.localUserID)
    store(ended)
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
      return try commit(wire, me: me.id)
    } catch {
      throw await translate(error, creating: false)
    }
  }

  private func updateControls(_ callID: CallID) throws -> CallSnapshot {
    guard let call = current, call.id == callID else { throw CallError.callNotFound }
    guard !call.state.isTerminal, call.state != .incoming else { throw CallError.invalidTransition }
    let updated = CallSnapshot(
      id: call.id, conversationID: call.conversationID, kind: call.kind, direction: call.direction,
      state: call.state, participants: call.participants, startedAt: call.startedAt,
      microphoneEnabled: controls.microphone, cameraEnabled: controls.camera,
      speakerEnabled: controls.speaker, cameraPosition: controls.position,
      canJoin: call.canJoin, localUserID: call.localUserID)
    store(updated)
    return updated
  }

  @discardableResult
  private func commit(_ wire: WireCallInfo, me: UserID) throws -> CallSnapshot {
    guard let snapshot = map(wire, me: me) else {
      throw VoIPError.invalidResponse
    }
    if snapshot.state == .active || snapshot.state == .ringing, lastHeartbeat == nil {
      lastHeartbeat = now()
    }
    store(snapshot)
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
