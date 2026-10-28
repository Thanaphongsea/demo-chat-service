nonisolated protocol CallClient: Sendable {
  var currentCall: CallSnapshot? { get async }
  func history() async -> [CallSnapshot]
  func startVideoCall(in conversation: Conversation) async throws -> CallSnapshot
  func answer(callID: CallID) async throws -> CallSnapshot
  func decline(callID: CallID) async throws -> CallSnapshot
  func end(callID: CallID) async throws -> CallSnapshot
  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot
  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot
  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot
  func flipCamera(callID: CallID) async throws -> CallSnapshot
  func demoIncomingCall(kind: CallKind) async throws -> CallSnapshot
  func demoMissedCall(kind: CallKind) async throws -> CallSnapshot
  func demoReconnect(callID: CallID) async throws -> CallSnapshot
  func events() async -> AsyncStream<CallEvent>
}
