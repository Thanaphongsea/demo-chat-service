import Foundation

nonisolated protocol DemoScheduler: Sendable {
  func sleep(for duration: Duration) async throws
}

nonisolated struct RuntimeDemoScheduler: DemoScheduler {
  nonisolated func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

nonisolated struct ImmediateDemoScheduler: DemoScheduler {
  nonisolated func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

actor ManualDemoScheduler: DemoScheduler {
  private typealias SleepContinuation = CheckedContinuation<Void, any Error>
  private struct Sleeper {
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }
  private var elapsed: Duration = .zero
  private var sleepers: [UUID: Sleeper] = [:]
  var pendingCount: Int { sleepers.count }

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    guard duration > .zero else { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: SleepContinuation) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          sleepers[id] = Sleeper(deadline: elapsed + duration, continuation: continuation)
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func advance(by duration: Duration = .milliseconds(300)) {
    guard duration >= .zero else { return }
    elapsed += duration
    let ready = sleepers.filter { $0.value.deadline <= elapsed }
    for (id, sleeper) in ready {
      sleepers.removeValue(forKey: id)
      sleeper.continuation.resume()
    }
  }

  private func cancel(_ id: UUID) {
    sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}
