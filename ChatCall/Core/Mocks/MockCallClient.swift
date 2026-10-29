import Foundation

actor MockCallClient: CallClient {
  private(set) var currentCall: CallSnapshot?
  private let seed: MockSeed
  private let scheduler: any DemoScheduler
  private var sequence = 0
  private var completed: [CallSnapshot] = []
  private var pendingTransition: Task<Void, Never>?
  private var observers: [UUID: AsyncStream<CallEvent>.Continuation] = [:]

  init(seed: MockSeed = .standard, scheduler: any DemoScheduler = ImmediateDemoScheduler()) {
    self.seed = seed
    self.scheduler = scheduler
  }

  deinit { pendingTransition?.cancel() }

  func history() async -> [CallSnapshot] { completed.reversed() }

  func startVideoCall(in conversation: Conversation) async throws -> CallSnapshot {
    let call = try begin(in: conversation, direction: .outgoing, state: .ringing)
    scheduleActivation(callID: call.id, from: .ringing)
    return call
  }

  func answer(callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.incoming])
    return commit(replacing(call, state: .active))
  }

  func decline(callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.incoming])
    return commit(replacing(call, state: .declined))
  }

  func end(callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.ringing, .active, .reconnecting])
    pendingTransition?.cancel()
    pendingTransition = nil
    return commit(replacing(call, state: .ended))
  }

  func join(callID: CallID) async throws -> CallSnapshot {
    guard currentCall == nil || currentCall?.state.isTerminal == true else {
      throw CallError.callAlreadyInProgress
    }
    guard let index = completed.lastIndex(where: { $0.id == callID && $0.canJoin }) else {
      throw CallError.invalidTransition
    }
    let rejoined = replacing(completed.remove(at: index), state: .active)
    return commit(rejoined)
  }

  func endForEveryone(callID: CallID) async throws -> CallSnapshot { try await end(callID: callID) }

  func reconcile() async {}

  func setVisibleVideoPeers(_ users: [UserID], callID: CallID) async {}

  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.ringing, .active, .reconnecting])
    return commit(replacing(call, microphoneEnabled: enabled))
  }

  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.ringing, .active, .reconnecting])
    return commit(replacing(call, cameraEnabled: enabled))
  }

  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.ringing, .active, .reconnecting])
    return commit(replacing(call, speakerEnabled: enabled))
  }

  func flipCamera(callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.ringing, .active, .reconnecting])
    return commit(replacing(call, cameraPosition: call.cameraPosition == .front ? .back : .front))
  }

  func demoIncomingCall(kind: CallKind) async throws -> CallSnapshot {
    try begin(in: demoConversation(kind: kind), direction: .incoming, state: .incoming)
  }

  func demoMissedCall(kind: CallKind) async throws -> CallSnapshot {
    try begin(
      in: demoConversation(kind: kind), direction: .incoming, state: .missed,
      canJoin: kind == .group)
  }

  func demoReconnect(callID: CallID) async throws -> CallSnapshot {
    let call = try require(callID, states: [.active])
    let reconnecting = commit(replacing(call, state: .reconnecting))
    scheduleActivation(callID: call.id, from: .reconnecting)
    return reconnecting
  }

  func events() async -> AsyncStream<CallEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<CallEvent>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  private func begin(
    in conversation: Conversation, direction: CallDirection, state: CallState,
    canJoin: Bool = false
  ) throws -> CallSnapshot {
    guard currentCall == nil || currentCall?.state.isTerminal == true else {
      throw CallError.callAlreadyInProgress
    }
    guard conversation.memberIDs.contains(MockSeed.currentUser.id) else {
      throw CallError.invalidConversation
    }
    guard conversation.memberIDs.count <= 16 else { throw CallError.capacityExceeded(maximum: 16) }
    let roster =
      [MockSeed.currentUser.id] + conversation.memberIDs.filter { $0 != MockSeed.currentUser.id }
    let participants = try roster.map { id in
      guard let user = seed.users.first(where: { $0.id == id }) else {
        throw CallError.userNotFound
      }
      return user
    }
    sequence += 1
    return commit(
      CallSnapshot(
        id: CallID("call-\(sequence)"), conversationID: conversation.id,
        kind: conversation.kind == .direct ? .direct : .group, direction: direction, state: state,
        participants: participants, startedAt: MockSeed.date.addingTimeInterval(Double(sequence)),
        microphoneEnabled: true, cameraEnabled: true, speakerEnabled: true, cameraPosition: .front,
        canJoin: canJoin))
  }

  private func demoConversation(kind: CallKind) throws -> Conversation {
    guard
      let conversation = seed.conversations.first(where: {
        ($0.kind == .direct) == (kind == .direct)
      })
    else { throw CallError.invalidConversation }
    return conversation
  }

  private func require(_ callID: CallID, states: [CallState]) throws -> CallSnapshot {
    guard let call = currentCall, call.id == callID else { throw CallError.callNotFound }
    guard states.contains(call.state) else { throw CallError.invalidTransition }
    return call
  }

  private func scheduleActivation(callID: CallID, from state: CallState) {
    pendingTransition?.cancel()
    pendingTransition = Task { [weak self, scheduler] in
      do {
        try await scheduler.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
        await self?.activate(callID: callID, from: state)
      } catch {
        // Ending a call cancels its delayed transition.
      }
    }
  }

  private func activate(callID: CallID, from state: CallState) {
    guard let call = currentCall, call.id == callID, call.state == state else { return }
    pendingTransition = nil
    _ = commit(replacing(call, state: .active))
  }

  private func commit(_ call: CallSnapshot) -> CallSnapshot {
    currentCall = call
    if call.state.isTerminal { completed.append(call) }
    for observer in observers.values { observer.yield(.callUpdated(call)) }
    return call
  }

  private func replacing(
    _ call: CallSnapshot, state: CallState? = nil,
    microphoneEnabled: Bool? = nil, cameraEnabled: Bool? = nil,
    speakerEnabled: Bool? = nil, cameraPosition: CameraPosition? = nil
  ) -> CallSnapshot {
    CallSnapshot(
      id: call.id, conversationID: call.conversationID, kind: call.kind,
      direction: call.direction, state: state ?? call.state, participants: call.participants,
      startedAt: call.startedAt, microphoneEnabled: microphoneEnabled ?? call.microphoneEnabled,
      cameraEnabled: cameraEnabled ?? call.cameraEnabled,
      speakerEnabled: speakerEnabled ?? call.speakerEnabled,
      cameraPosition: cameraPosition ?? call.cameraPosition)
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
