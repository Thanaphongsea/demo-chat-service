import Foundation

nonisolated enum CallKind: String, Sendable { case direct, group }
nonisolated enum CallDirection: Sendable { case incoming, outgoing }
nonisolated enum CameraPosition: Sendable { case front, back }
nonisolated enum CallState: Sendable {
  case incoming, ringing, active, reconnecting, declined, missed, ended
  var isTerminal: Bool { self == .declined || self == .missed || self == .ended }
}

nonisolated struct CallSnapshot: Identifiable, Equatable, Sendable {
  let id: CallID
  let conversationID: ConversationID
  let kind: CallKind
  let direction: CallDirection
  let state: CallState
  let participants: [User]
  let startedAt: Date
  let microphoneEnabled: Bool
  let cameraEnabled: Bool
  let speakerEnabled: Bool
  let cameraPosition: CameraPosition
  /// The server says the viewer may enter this call again: a group call they missed, declined or left
  /// while the group is still running. Never true for a live or ended-for-everyone call.
  var canJoin = false
  /// The viewer's own id, so views do not assume the mock user.
  var localUserID = MockSeed.currentUser.id
}

nonisolated enum CallEvent: Equatable, Sendable { case callUpdated(CallSnapshot) }
nonisolated enum CallError: Error, Equatable, Sendable {
  case callNotFound, invalidTransition, callAlreadyInProgress, invalidConversation, userNotFound
  case capacityExceeded(maximum: Int)
  /// The operation exists only for the mock (demo calls) or has no live mapping yet.
  case unsupported
  /// Calls are not connected to a call service in this build or launch (no VoIP URL).
  case notConfigured
}
