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
}

nonisolated enum CallEvent: Equatable, Sendable { case callUpdated(CallSnapshot) }
nonisolated enum CallError: Error, Equatable, Sendable {
  case callNotFound, invalidTransition, callAlreadyInProgress, invalidConversation, userNotFound
  case capacityExceeded(maximum: Int)
}
