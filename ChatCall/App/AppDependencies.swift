import Foundation
import OSLog
import SwiftUI

nonisolated struct AppDependencies: Sendable {
  let auth: any AuthClient
  let chat: any ChatClient
  let calls: any CallClient

  /// Real login against the identity service; chat and calls stay mocked until their contracts exist.
  static func live(
    configuration: AuthConfiguration, arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> AppDependencies {
    let mocked = mock(arguments: arguments)
    return AppDependencies(
      auth: LiveAuthClient(configuration: configuration), chat: mocked.chat, calls: mocked.calls)
  }

  /// Real login by default; `-demo-mock` or `-demo-immediateEvents` (UI tests) selects the full mock.
  static func launch(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDependencies {
    let useMock = arguments.contains("-demo-mock") || arguments.contains("-demo-immediateEvents")
    guard !useMock else {
      authLog.notice("auth: using MOCK client")
      return mock(arguments: arguments)
    }
    let configuration = AuthConfiguration()
    let endpoint = configuration.baseURL.absoluteString
    authLog.notice(
      "auth: using LIVE client \(endpoint, privacy: .public) app_id=\(configuration.appID, privacy: .public)"
    )
    return live(configuration: configuration)
  }

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
