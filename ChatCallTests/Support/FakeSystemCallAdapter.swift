import Foundation

@testable import ChatCall

nonisolated final class FakeSystemCallAdapter: SystemCallAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private var uuids: [UUID] = []
  private let continuation: AsyncStream<SystemCallAction>.Continuation
  let userActions: AsyncStream<SystemCallAction>

  init() { (userActions, continuation) = AsyncStream<SystemCallAction>.makeStream() }

  var commands: [String] { lock.withLock { recorded } }
  var firstUUID: UUID? { lock.withLock { uuids.first } }

  private func add(_ text: String, _ uuid: UUID) {
    lock.withLock {
      recorded.append(text)
      if !uuids.contains(uuid) { uuids.append(uuid) }
    }
  }

  func reportIncoming(uuid: UUID, name: String, hasVideo: Bool) { add("incoming(\(name),video=\(hasVideo))", uuid) }
  func reportOutgoingStarted(uuid: UUID, name: String, hasVideo: Bool) { add("outgoingStarted(\(name))", uuid) }
  func reportOutgoingConnected(uuid: UUID) { add("outgoingConnected", uuid) }
  func reportAnswered(uuid: UUID) { add("answered", uuid) }
  func reportEnded(uuid: UUID, reason: SystemCallEnd) { add("ended(\(reason))", uuid) }

  func user(_ action: SystemCallAction) { continuation.yield(action) }
}
