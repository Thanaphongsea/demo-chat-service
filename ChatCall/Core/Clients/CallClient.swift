nonisolated protocol CallClient: Sendable {
  var currentCall: CallSnapshot? { get async }
  func history() async -> [CallSnapshot]
  func startVideoCall(in conversation: Conversation) async throws -> CallSnapshot
  func answer(callID: CallID) async throws -> CallSnapshot
  func decline(callID: CallID) async throws -> CallSnapshot
  /// Leave (group), cancel or end (direct) for the viewer.
  func end(callID: CallID) async throws -> CallSnapshot
  /// Re-enter a group call the viewer missed, declined or left while it is still running.
  func join(callID: CallID) async throws -> CallSnapshot
  /// The creator ends a group call for everyone.
  func endForEveryone(callID: CallID) async throws -> CallSnapshot
  /// The remote users whose video the screen shows (the current page); audio always flows for everyone.
  func setVisibleVideoPeers(_ users: [UserID], callID: CallID) async
  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot
  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot
  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot
  func flipCamera(callID: CallID) async throws -> CallSnapshot
  func demoIncomingCall(kind: CallKind) async throws -> CallSnapshot
  func demoMissedCall(kind: CallKind) async throws -> CallSnapshot
  func demoReconnect(callID: CallID) async throws -> CallSnapshot
  func events() async -> AsyncStream<CallEvent>
}
