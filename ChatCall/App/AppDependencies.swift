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
    let chat: any ChatClient
    if arguments.contains("-demo-emptyConversations") {
      chat = ConversationFixtureClient(fixture: .empty)
    } else if arguments.contains("-demo-failConversationLoadOnce") {
      chat = ConversationFixtureClient(fixture: .failOnce)
    } else if arguments.contains("-demo-failMessageSendOnce") {
      chat = ChatRoomFixtureClient(fixture: .failSendOnce, scheduler: scheduler)
    } else {
      chat = MockChatClient(scheduler: scheduler)
    }
    return AppDependencies(
      auth: MockAuthClient(scheduler: scheduler),
      chat: chat,
      calls: MockCallClient(
        scheduler: arguments.contains("-demo-immediateEvents")
          ? scheduler : RuntimeDemoScheduler(minimumDelay: .seconds(3))))
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
