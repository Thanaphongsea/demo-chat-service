import Foundation
import OSLog
import SwiftUI

/// Fires when the server ended the session (kicked, revoked or unauthorised) so the app can return to Login.
nonisolated final class SessionEndedSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  func stream() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let id = UUID()
    lock.withLock { continuations[id] = continuation }
    continuation.onTermination = { [weak self] _ in
      self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  func fire() {
    let targets = lock.withLock { Array(continuations.values) }
    for continuation in targets { continuation.yield() }
  }
}

nonisolated struct AppDependencies: Sendable {
  let auth: any AuthClient
  let chat: any ChatClient
  let calls: any CallClient
  let sessionEnded: SessionEndedSignal
  /// Stops background work that outlives a screen, e.g. the realtime socket, on sign-out.
  let stopBackgroundWork: @Sendable () async -> Void

  init(
    auth: any AuthClient, chat: any ChatClient, calls: any CallClient,
    sessionEnded: SessionEndedSignal = SessionEndedSignal(),
    stopBackgroundWork: @escaping @Sendable () async -> Void = {}
  ) {
    self.auth = auth
    self.chat = chat
    self.calls = calls
    self.sessionEnded = sessionEnded
    self.stopBackgroundWork = stopBackgroundWork
  }

  /// Real login and chat against the gateway; calls stay mocked until the VoIP client lands.
  static func live(
    configuration: AuthConfiguration, gateway: GatewayConfiguration = GatewayConfiguration(),
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> AppDependencies {
    let mocked = mock(arguments: arguments)
    let auth = LiveAuthClient(configuration: configuration)
    let signal = SessionEndedSignal()
    let chat = LiveChatClient(
      gateway: GatewayClient(configuration: gateway, tokens: auth),
      currentUser: { await auth.currentSession?.user.id },
      realtime: CentrifugoRealtime(configuration: gateway, tokens: auth),
      deviceID: DeviceIdentifier.current(),
      onKicked: {
        await auth.signOut()
        signal.fire()
      })
    return AppDependencies(
      auth: auth, chat: chat, calls: mocked.calls, sessionEnded: signal,
      stopBackgroundWork: { await chat.stopRealtime() })
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
