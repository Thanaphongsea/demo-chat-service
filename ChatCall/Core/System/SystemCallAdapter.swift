import Foundation

nonisolated enum SystemCallEnd: Equatable, Sendable {
  case remoteEnded, declined, unanswered, failed
}

/// What the user did in the system call UI (lock screen, banner, Recents, a Bluetooth headset).
nonisolated enum SystemCallAction: Equatable, Sendable {
  case answer(UUID)
  case end(UUID)
  case setMuted(UUID, Bool)
}

/// The system's view of calls (CallKit). Methods are fire-and-forget and ordered; the system's answer to
/// each arrives, if at all, as a `SystemCallAction`.
nonisolated protocol SystemCallAdapter: Sendable {
  func reportIncoming(uuid: UUID, name: String, hasVideo: Bool)
  func reportOutgoingStarted(uuid: UUID, name: String, hasVideo: Bool)
  func reportOutgoingConnected(uuid: UUID)
  /// The call was answered inside the app: tell the system so its UI does not keep ringing.
  func reportAnswered(uuid: UUID)
  func reportEnded(uuid: UUID, reason: SystemCallEnd)
  var userActions: AsyncStream<SystemCallAction> { get }
}
