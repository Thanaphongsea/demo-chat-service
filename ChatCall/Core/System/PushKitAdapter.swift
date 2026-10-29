import Foundation
import OSLog
import PushKit

nonisolated private let pushLog = Logger(subsystem: "com.example.ChatCall", category: "push")

/// Where a VoIP push token goes. **No backend accepts one yet**: the supplied service only stores FCM
/// registration tokens, and a PushKit token must never be sent to that endpoint.
nonisolated protocol VoIPPushTokenSink: Sendable {
  func register(token: String) async
}

/// The default sink: keeps the token on the device and says why it is not uploaded.
nonisolated struct UnregisteredVoIPPushTokenSink: VoIPPushTokenSink {
  func register(token: String) async {
    pushLog.notice("VoIP push token received (\(token.count) chars); not uploaded: no APNs VoIP registry on the backend")
  }
}

/// Receives VoIP pushes. Every push **must** be reported to CallKit before its completion handler runs, so
/// the handler reports first (`onIncoming`) and never waits for the network.
///
/// The payload keys read here (`call_id`, `caller_name`) are a proposal for the backend to agree to; the
/// handoff defines no APNs payload and no sender exists, so this path is untested against a real push.
final class PushKitAdapter: NSObject, PKPushRegistryDelegate {
  private var registry: PKPushRegistry?
  private let sink: any VoIPPushTokenSink
  private let onIncoming: @MainActor (_ callID: String?, _ callerName: String?) -> Void

  init(
    sink: any VoIPPushTokenSink = UnregisteredVoIPPushTokenSink(),
    onIncoming: @escaping @MainActor (_ callID: String?, _ callerName: String?) -> Void
  ) {
    self.sink = sink
    self.onIncoming = onIncoming
  }

  @MainActor func start() {
    guard registry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
  ) {
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    let sink = sink
    Task { await sink.register(token: token) }
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    let values = payload.dictionaryPayload
    let callID = values["call_id"] as? String
    let caller = values["caller_name"] as? String
    MainActor.assumeIsolated { onIncoming(callID, caller) }
    completion()
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    pushLog.notice("VoIP push token invalidated")
  }
}
