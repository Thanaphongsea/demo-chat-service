import AVFoundation
import CallKit
import OSLog

nonisolated private let systemCallLog = Logger(subsystem: "com.example.ChatCall", category: "system-call")

/// The CallKit side of calls: shows the system incoming UI, mirrors outgoing and ended calls, forwards the
/// user's system actions, and hands CallKit's audio session activation to WebRTC.
nonisolated final class CallKitAdapter: NSObject, SystemCallAdapter, CXProviderDelegate, @unchecked Sendable {
  private let provider: CXProvider
  private let controller = CXCallController()
  private let continuation: AsyncStream<SystemCallAction>.Continuation
  let userActions: AsyncStream<SystemCallAction>

  override init() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = true
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = false
    provider = CXProvider(configuration: configuration)
    (userActions, continuation) = AsyncStream<SystemCallAction>.makeStream()
    super.init()
    provider.setDelegate(self, queue: nil)
    AudioSessionController.systemActivatesAudio = true
  }

  // MARK: SystemCallAdapter

  func reportIncoming(uuid: UUID, name: String, hasVideo: Bool) {
    provider.reportNewIncomingCall(with: uuid, update: Self.update(name: name, hasVideo: hasVideo)) {
      error in
      if let error { systemCallLog.error("incoming call not shown: \(error.localizedDescription, privacy: .public)") }
    }
  }

  func reportOutgoingStarted(uuid: UUID, name: String, hasVideo: Bool) {
    let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
    action.isVideo = hasVideo
    request(action)
  }

  func reportOutgoingConnected(uuid: UUID) {
    provider.reportOutgoingCall(with: uuid, connectedAt: nil)
  }

  func reportAnswered(uuid: UUID) { request(CXAnswerCallAction(call: uuid)) }

  func reportEnded(uuid: UUID, reason: SystemCallEnd) {
    let mapped: CXCallEndedReason =
      switch reason {
      case .remoteEnded: .remoteEnded
      case .declined: .declinedElsewhere
      case .unanswered: .unanswered
      case .failed: .failed
      }
    provider.reportCall(with: uuid, endedAt: nil, reason: mapped)
  }

  // MARK: CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {}

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    continuation.yield(.answer(action.callUUID))
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    continuation.yield(.end(action.callUUID))
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    continuation.yield(.setMuted(action.callUUID, action.isMuted))
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    AudioSessionController.systemDidActivate(audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    AudioSessionController.systemDidDeactivate(audioSession)
  }

  // MARK: helpers

  private func request(_ action: CXAction) {
    controller.request(CXTransaction(action: action)) { error in
      if let error { systemCallLog.error("system call request failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  private static func update(name: String, hasVideo: Bool) -> CXCallUpdate {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: name)
    update.localizedCallerName = name
    update.hasVideo = hasVideo
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }
}
