import Foundation

/// A failed async contract must produce a timed assertion instead of hanging the test runner.
@MainActor
func waitUntil(
  timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline, !Task.isCancelled {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return false
}

actor EventProbe<Event: Sendable> {
  private var values: [Event] = []
  private var task: Task<Void, Never>?

  func start(stream: AsyncStream<Event>) {
    task = Task { [weak self] in
      for await value in stream { await self?.append(value) }
    }
  }

  var count: Int { values.count }
  func value(at index: Int) -> Event? { values.indices.contains(index) ? values[index] : nil }
  func cancel() { task?.cancel() }
  private func append(_ value: Event) { values.append(value) }
}
