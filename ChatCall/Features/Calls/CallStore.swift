import Observation

@MainActor
@Observable
final class CallStore {
  private(set) var call: CallSnapshot?
  private(set) var history: [CallSnapshot] = []
  var isPresented = false
  private(set) var errorMessage: String?
  var page = VideoPage(localUser: MockSeed.currentUser)
  private(set) var isBusy = false
  @ObservationIgnored private let client: any CallClient
  @ObservationIgnored private let chatClient: any ChatClient
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var streamTask: Task<AsyncStream<CallEvent>, Never>?
  @ObservationIgnored private var cleanupTask: Task<Void, Never>?
  @ObservationIgnored private var operationTask: Task<CallSnapshot, any Error>?
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var retiredIDs: Set<CallID> = []

  init(client: any CallClient, chatClient: any ChatClient) {
    self.client = client
    self.chatClient = chatClient
  }

  func start() async {
    let attempt = revision
    await cleanupTask?.value
    guard attempt == revision, !Task.isCancelled else { return }
    await observeEvents(revision: attempt)
    let completed = await client.history()
    let current = await client.currentCall
    guard attempt == revision, !Task.isCancelled else { return }
    for snapshot in completed {
      guard !retiredIDs.contains(snapshot.id), !history.contains(where: { $0.id == snapshot.id })
      else { continue }
      history.append(snapshot)
    }
    history.sort { $0.startedAt > $1.startedAt }
    if let current, !current.state.isTerminal { receive(.callUpdated(current)) }
  }

  func startVideo(in id: ConversationID) async {
    await perform { [chatClient, client] in
      guard
        let conversation = try await chatClient.listConversations().first(where: { $0.id == id })
      else { throw CallError.invalidConversation }
      try Task.checkCancellation()
      return try await client.startVideoCall(in: conversation)
    }
  }

  func incoming(kind: CallKind) async {
    await perform { [client] in try await client.demoIncomingCall(kind: kind) }
  }

  func missed(kind: CallKind) async {
    await perform { [client] in try await client.demoMissedCall(kind: kind) }
  }

  func answer() async {
    guard let call, call.state == .incoming else { return }
    await perform { [client] in try await client.answer(callID: call.id) }
  }

  func decline() async {
    guard let call, call.state == .incoming else { return }
    await perform { [client] in try await client.decline(callID: call.id) }
  }

  func end() async {
    guard let call, !call.state.isTerminal, call.state != .incoming else { return }
    await perform { [client] in try await client.end(callID: call.id) }
  }

  func toggleMicrophone() async {
    guard let call, canControl else { return }
    await perform { [client] in
      try await client.setMicrophoneEnabled(!call.microphoneEnabled, callID: call.id)
    }
  }

  func toggleCamera() async {
    guard let call, canControl else { return }
    await perform { [client] in
      try await client.setCameraEnabled(!call.cameraEnabled, callID: call.id)
    }
  }

  func toggleSpeaker() async {
    guard let call, canControl else { return }
    await perform { [client] in
      try await client.setSpeakerEnabled(!call.speakerEnabled, callID: call.id)
    }
  }

  func flipCamera() async {
    guard let call, canControl else { return }
    await perform { [client] in try await client.flipCamera(callID: call.id) }
  }

  func reconnect() async {
    guard let call, call.state == .active else { return }
    await perform { [client] in try await client.demoReconnect(callID: call.id) }
  }

  var canControl: Bool {
    guard let call else { return false }
    return !call.state.isTerminal && call.state != .incoming
  }

  func receive(_ event: CallEvent) {
    guard case .callUpdated(let updated) = event, !retiredIDs.contains(updated.id) else { return }
    guard call?.id == updated.id || !history.contains(where: { $0.id == updated.id }) else {
      return
    }
    if let current = call, current.id == updated.id {
      guard !current.state.isTerminal, validTransition(from: current.state, to: updated.state)
      else {
        return
      }
    } else {
      guard call == nil || call?.state.isTerminal == true else { return }
      if let call { retiredIDs.insert(call.id) }
      page = VideoPage(localUser: MockSeed.currentUser)
    }
    call = updated
    page.update(
      participants: updated.participants,
      audioOnlyIDs: updated.cameraEnabled ? [] : [MockSeed.currentUser.id])
    if updated.state.isTerminal {
      if !history.contains(where: { $0.id == updated.id }) { history.insert(updated, at: 0) }
    } else {
      isPresented = true
    }
  }

  func dismiss() {
    guard let call, call.state.isTerminal else { return }
    retiredIDs.insert(call.id)
    self.call = nil
    isPresented = false
  }

  func reset() {
    revision += 1
    operationTask?.cancel()
    eventTask?.cancel()
    eventTask = nil
    streamTask?.cancel()
    streamTask = nil
    retiredIDs.formUnion(history.map(\.id))
    if let call { retiredIDs.insert(call.id) }
    call = nil
    history = []
    page = VideoPage(localUser: MockSeed.currentUser)
    isPresented = false
    isBusy = false
    errorMessage = nil
    let previousCleanup = cleanupTask
    let pendingOperation = operationTask
    operationTask = nil
    cleanupTask = Task { [weak self, client] in
      await previousCleanup?.value
      _ = try? await pendingOperation?.value
      let completed = await client.history()
      self?.retiredIDs.formUnion(completed.map(\.id))
      if let current = await client.currentCall {
        self?.retiredIDs.insert(current.id)
        guard !current.state.isTerminal else { return }
        if current.state == .incoming {
          _ = try? await client.decline(callID: current.id)
        } else {
          _ = try? await client.end(callID: current.id)
        }
      }
    }
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> CallSnapshot) async {
    guard !isBusy, !Task.isCancelled else { return }
    isBusy = true
    errorMessage = nil
    let attempt = revision
    defer {
      if attempt == revision {
        isBusy = false
        operationTask = nil
      }
    }
    await cleanupTask?.value
    guard attempt == revision, !Task.isCancelled else { return }
    await observeEvents(revision: attempt)
    guard attempt == revision, !Task.isCancelled else { return }
    let task = Task {
      try Task.checkCancellation()
      return try await operation()
    }
    operationTask = task
    do {
      let snapshot = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard attempt == revision, !Task.isCancelled else {
        await terminate(snapshot)
        return
      }
      receive(.callUpdated(snapshot))
    } catch {
      guard attempt == revision, !(error is CancellationError), !Task.isCancelled else { return }
      errorMessage =
        (error as? CallError) == .capacityExceeded(maximum: 16)
        ? "Video calls support up to 16 people, including you."
        : "Unable to update the call. Please try again."
    }
  }

  private func observeEvents(revision attempt: Int) async {
    guard eventTask == nil else { return }
    if streamTask == nil { streamTask = Task { [client] in await client.events() } }
    guard let stream = await streamTask?.value, attempt == revision, eventTask == nil else {
      return
    }
    eventTask = Task { [weak self] in
      for await event in stream {
        guard let self, !Task.isCancelled, self.revision == attempt else { return }
        self.receive(event)
      }
    }
  }

  private func terminate(_ snapshot: CallSnapshot) async {
    guard !snapshot.state.isTerminal else { return }
    if snapshot.state == .incoming {
      _ = try? await client.decline(callID: snapshot.id)
    } else {
      _ = try? await client.end(callID: snapshot.id)
    }
  }

  private func validTransition(from: CallState, to target: CallState) -> Bool {
    if from == target { return true }
    switch from {
    case .incoming: return [.active, .declined, .missed, .ended].contains(target)
    case .ringing: return [.active, .ended, .missed, .declined].contains(target)
    case .active: return [.reconnecting, .ended].contains(target)
    case .reconnecting: return [.active, .ended].contains(target)
    case .declined, .missed, .ended: return false
    }
  }
}
