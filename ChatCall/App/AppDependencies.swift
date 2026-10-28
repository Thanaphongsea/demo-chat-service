import Foundation
import SwiftUI

nonisolated struct AppDependencies: Sendable {
  let auth: any AuthClient
  let chat: any ChatClient
  let calls: any CallClient

  static func mock(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDependencies {
    let scheduler: any DemoScheduler =
      arguments.contains("-demo-immediateEvents")
      ? ImmediateDemoScheduler() : RuntimeDemoScheduler()
    return AppDependencies(
      auth: MockAuthClient(scheduler: scheduler),
      chat: MockChatClient(scheduler: scheduler),
      calls: MockCallClient(scheduler: scheduler))
  }
}

private struct AppDependenciesKey: EnvironmentKey {
  static let defaultValue = AppDependencies.mock()
}

extension EnvironmentValues {
  var appDependencies: AppDependencies {
    get { self[AppDependenciesKey.self] }
    set { self[AppDependenciesKey.self] = newValue }
  }
}
