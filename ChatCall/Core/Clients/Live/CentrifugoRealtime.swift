import Foundation
import SwiftCentrifuge

/// The shared Centrifugo socket. The access token's `channels` claim already subscribes `user:<me>`,
/// so every event for this user arrives as a server-side publication with no explicit subscribe.
nonisolated final class CentrifugoRealtime: RealtimeConnection, @unchecked Sendable {
  private let configuration: GatewayConfiguration
  private let tokens: any AccessTokenProvider
  private let lock = NSLock()
  private var client: CentrifugeClient?
  private var bridge: Bridge?
  private var continuations: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]

  init(configuration: GatewayConfiguration, tokens: any AccessTokenProvider) {
    self.configuration = configuration
    self.tokens = tokens
  }

  func start() async {
    lock.withLock {
      guard client == nil else { return }
      let bridge = Bridge { [weak self] event in self?.broadcast(event) }
      let tokens = tokens
      let config = CentrifugeClientConfig(
        name: "ios", useNativeWebSocket: true,
        tokenGetter: { _, completion in
          nonisolated(unsafe) let done = completion
          Task {
            do {
              done(.success(try await tokens.validToken().value))
            } catch {
              if let auth = error as? AuthError, auth == .revoked || auth == .invalidCredentials {
                bridge.emit(.kicked(deviceID: nil))
              }
              done(.failure(error))
            }
          }
        })
      let client = CentrifugeClient(
        endpoint: configuration.websocketURL.absoluteString, config: config, delegate: bridge)
      self.client = client
      self.bridge = bridge
      client.connect()
    }
  }

  func stop() async {
    let stopped = lock.withLock { () -> CentrifugeClient? in
      defer {
        client = nil
        bridge = nil
      }
      return client
    }
    stopped?.disconnect()
  }

  func events() -> AsyncStream<RealtimeEvent> {
    let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
    let id = UUID()
    lock.withLock { continuations[id] = continuation }
    continuation.onTermination = { [weak self] _ in
      self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  private func broadcast(_ event: RealtimeEvent) {
    let targets = lock.withLock { Array(continuations.values) }
    for continuation in targets { continuation.yield(event) }
  }

  /// Receives the SDK callbacks; connections after the first are reported as `.reconnected`.
  private final class Bridge: CentrifugeClientDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connectedBefore = false
    let emit: @Sendable (RealtimeEvent) -> Void

    init(emit: @escaping @Sendable (RealtimeEvent) -> Void) { self.emit = emit }

    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
      let again = lock.withLock { () -> Bool in
        defer { connectedBefore = true }
        return connectedBefore
      }
      if again { emit(.reconnected) }
    }

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {
      if let decoded = RealtimeEventDecoder.decode(event.data) { emit(decoded) }
    }

    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {}
    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {}
    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
      chatLog.error("realtime error: \(String(describing: type(of: event.error)), privacy: .public)")
    }
    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent) {}
    func onSubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribedEvent) {}
    func onUnsubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribedEvent) {}
    func onSubscribing(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribingEvent) {}
    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent) {}
    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent) {}
  }
}
