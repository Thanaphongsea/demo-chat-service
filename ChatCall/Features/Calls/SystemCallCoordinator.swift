import Foundation
import UIKit

/// Keeps the system call UI (CallKit) and the app's call state in step. CallKit is used only for calls the
/// app cannot show itself, i.e. those delivered by a VoIP push while it is not in the foreground. While the
/// app is open the in-app call screen is the call UI and the app manages audio itself: reporting those calls
/// to CallKit as well made it end a freshly answered call and never activate the audio session.
@MainActor
final class SystemCallCoordinator {
  private let store: CallStore
  private let client: any CallClient
  private let adapter: any SystemCallAdapter
  private var uuids: [CallID: UUID] = [:]
  private var states: [CallID: CallState] = [:]
  private var systemAnswered: Set<UUID> = []
  /// Calls reported from a push whose server call has not been matched yet.
  private var pendingPushes: Set<UUID> = []
  /// Calls the system call UI knows about; only these are mirrored to CallKit.
  private var reported: Set<CallID> = []
  private let isForeground: @MainActor () -> Bool
  private var eventTask: Task<Void, Never>?
  private var actionTask: Task<Void, Never>?
  private let pushWait: Duration

  init(
    store: CallStore, client: any CallClient, adapter: any SystemCallAdapter,
    pushWait: Duration = .seconds(8),
    isForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
  ) {
    self.isForeground = isForeground
    self.store = store
    self.client = client
    self.adapter = adapter
    self.pushWait = pushWait
  }

  func start() {
    guard eventTask == nil else { return }
    eventTask = Task { [weak self, client] in
      for await event in await client.events() {
        guard let self, !Task.isCancelled else { return }
        self.handle(event)
      }
    }
    actionTask = Task { [weak self, adapter] in
      for await action in adapter.userActions {
        guard let self, !Task.isCancelled else { return }
        await self.perform(action)
      }
    }
  }

  /// Ends every call the system knows about and stops observing; used on sign-out.
  func reset() {
    eventTask?.cancel()
    actionTask?.cancel()
    eventTask = nil
    actionTask = nil
    for uuid in uuids.values { adapter.reportEnded(uuid: uuid, reason: .remoteEnded) }
    uuids = [:]
    states = [:]
    systemAnswered = []
    pendingPushes = []
    reported = []
    AudioSessionController.systemActivatesAudio = false
  }

  /// A VoIP push arrived. The system requires an incoming call to be reported immediately, before any
  /// network round trip, so report first and reconcile with the server afterwards.
  func handlePush(callID: String?, callerName: String?) {
    let id = callID.map { CallID($0) }
    if let id, uuids[id] != nil { return }
    let uuid = UUID()
    if let id {
      uuids[id] = uuid
      reported.insert(id)
    }
    AudioSessionController.systemActivatesAudio = true
    pendingPushes.insert(uuid)
    adapter.reportIncoming(
      uuid: uuid, name: (callerName?.isEmpty == false ? callerName : nil) ?? "Incoming call",
      hasVideo: true)
    Task { [weak self, client, pushWait] in
      await client.reconcile()
      try? await Task.sleep(for: pushWait)
      guard let self, self.pendingPushes.remove(uuid) != nil else { return }
      // No matching call appeared: it ended, was answered elsewhere, or never existed.
      let matched = id.map { self.states[$0] != nil || self.store.call?.id == $0 } ?? false
      guard !matched else { return }
      self.adapter.reportEnded(uuid: uuid, reason: .unanswered)
      if let id { self.uuids.removeValue(forKey: id) }
    }
  }

  // MARK: events

  private func handle(_ event: CallEvent) {
    guard case .callUpdated(let call) = event else { return }
    let previous = states[call.id]
    guard previous != call.state else { return }
    states[call.id] = call.state
    let name = call.displayName
    switch call.state {
    case .incoming:
      // A push may have reported this call already; otherwise only report it when the app is not open.
      if uuids[call.id] == nil, !isForeground() {
        let uuid = UUID()
        uuids[call.id] = uuid
        reported.insert(call.id)
        AudioSessionController.systemActivatesAudio = true
        adapter.reportIncoming(uuid: uuid, name: name, hasVideo: true)
      }
    case .ringing:
      break  // an outgoing call is placed from inside the app
    case .active:
      guard reported.contains(call.id), let uuid = uuids[call.id] else { break }
      // An answer made in the system UI already told the system; only an in-app answer must.
      if previous == .incoming, systemAnswered.remove(uuid) == nil {
        adapter.reportAnswered(uuid: uuid)
      }
    case .reconnecting:
      break
    case .declined, .missed, .ended:
      defer { states.removeValue(forKey: call.id) }
      guard reported.remove(call.id) != nil, let uuid = uuids.removeValue(forKey: call.id) else { break }
      adapter.reportEnded(uuid: uuid, reason: Self.reason(for: call.state))
      systemAnswered.remove(uuid)
      if reported.isEmpty { AudioSessionController.systemActivatesAudio = false }
    }
  }

  private static func reason(for state: CallState) -> SystemCallEnd {
    switch state {
    case .declined: .declined
    case .missed: .unanswered
    default: .remoteEnded
    }
  }

  // MARK: user actions

  private func perform(_ action: SystemCallAction) async {
    switch action {
    case .answer(let uuid):
      guard let id = callID(for: uuid) else { return }
      systemAnswered.insert(uuid)
      guard await waitForCall(id) else { return }
      await store.answer()
    case .end(let uuid):
      callLog.notice("coordinator: system end action")
      guard let id = callID(for: uuid) else { return }
      guard await waitForCall(id, brief: true), let call = store.call else { return }
      if call.state == .incoming { await store.decline() } else { await store.end() }
    case .setMuted(let uuid, let muted):
      guard let id = callID(for: uuid), store.call?.id == id,
        store.call?.microphoneEnabled == muted
      else { return }
      await store.toggleMicrophone()
    }
  }

  private func callID(for uuid: UUID) -> CallID? { uuids.first { $0.value == uuid }?.key }

  /// An answer from a push can arrive before the poll has delivered the call; give it a moment.
  private func waitForCall(_ id: CallID, brief: Bool = false) async -> Bool {
    for _ in 0..<(brief ? 5 : 50) {
      if store.call?.id == id { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return store.call?.id == id
  }
}
