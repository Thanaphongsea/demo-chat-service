import Foundation

/// Calls for a live app with no VoIP URL: the demo actions still work on the mock, but a real
/// conversation cannot be called, and the user is told why instead of seeing a generic failure.
actor UnconfiguredCallClient: CallClient {
  private let demo = MockCallClient()

  var currentCall: CallSnapshot? { get async { await demo.currentCall } }
  func history() async -> [CallSnapshot] { await demo.history() }
  func startVideoCall(in conversation: Conversation) async throws -> CallSnapshot {
    throw CallError.notConfigured
  }
  func answer(callID: CallID) async throws -> CallSnapshot { try await demo.answer(callID: callID) }
  func decline(callID: CallID) async throws -> CallSnapshot { try await demo.decline(callID: callID) }
  func end(callID: CallID) async throws -> CallSnapshot { try await demo.end(callID: callID) }
  func join(callID: CallID) async throws -> CallSnapshot { try await demo.join(callID: callID) }
  func endForEveryone(callID: CallID) async throws -> CallSnapshot {
    try await demo.endForEveryone(callID: callID)
  }
  func setVisibleVideoPeers(_ users: [UserID], callID: CallID) async {}
  func setMicrophoneEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    try await demo.setMicrophoneEnabled(enabled, callID: callID)
  }
  func setCameraEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    try await demo.setCameraEnabled(enabled, callID: callID)
  }
  func setSpeakerEnabled(_ enabled: Bool, callID: CallID) async throws -> CallSnapshot {
    try await demo.setSpeakerEnabled(enabled, callID: callID)
  }
  func flipCamera(callID: CallID) async throws -> CallSnapshot { try await demo.flipCamera(callID: callID) }
  func demoIncomingCall(kind: CallKind) async throws -> CallSnapshot { try await demo.demoIncomingCall(kind: kind) }
  func demoMissedCall(kind: CallKind) async throws -> CallSnapshot { try await demo.demoMissedCall(kind: kind) }
  func demoReconnect(callID: CallID) async throws -> CallSnapshot { try await demo.demoReconnect(callID: callID) }
  func reconcile() async {}
  func events() async -> AsyncStream<CallEvent> { await demo.events() }
}
