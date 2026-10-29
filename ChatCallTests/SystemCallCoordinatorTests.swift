import Foundation
import Testing

@testable import ChatCall

@MainActor
struct SystemCallCoordinatorTests {
  struct Rig {
    let client: MockCallClient
    let store: CallStore
    let adapter: FakeSystemCallAdapter
    let coordinator: SystemCallCoordinator
  }

  private func rig(
    pushWait: Duration = .milliseconds(150), foreground: Bool = false, mirrorInApp: Bool = false
  ) async -> Rig {
    let client = MockCallClient()
    let store = CallStore(client: client, chatClient: MockChatClient())
    let adapter = FakeSystemCallAdapter()
    let coordinator = SystemCallCoordinator(
      store: store, client: client, adapter: adapter, pushWait: pushWait, isForeground: { foreground }, mirrorInAppCalls: mirrorInApp)
    coordinator.start()
    await store.start()
    try? await Task.sleep(for: .milliseconds(20))
    return Rig(client: client, store: store, adapter: adapter, coordinator: coordinator)
  }

  private func finish(_ rig: Rig) {
    rig.coordinator.reset()
    rig.store.reset()
  }

  @Test("An incoming call is reported to the system once, however many updates follow")
  func reportsIncomingOnce() async throws {
    let rig = await rig()
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.adapter.commands.count >= 1 })
    #expect(rig.adapter.commands.first?.hasPrefix("incoming(") == true)
    #expect(rig.adapter.commands.first?.hasSuffix("video=true)") == true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.adapter.commands.filter { $0.hasPrefix("incoming(") }.count == 1)
    finish(rig)
  }

  @Test("Answering inside the app tells the system; ending reports why it ended")
  func inAppAnswerAndEnd() async throws {
    let rig = await rig()
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.store.call?.state == .incoming })
    await rig.store.answer()
    try #require(await waitUntil { rig.adapter.commands.contains("answered") })
    await rig.store.end()
    try #require(await waitUntil { rig.adapter.commands.contains("ended(remoteEnded)") })
    finish(rig)
  }

  @Test("A declined call ends with the matching system reason; a call missed before it rang is not reported")
  func endReasons() async throws {
    let declined = await rig()
    _ = try await declined.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { declined.store.call?.state == .incoming })
    await declined.store.decline()
    try #require(await waitUntil { declined.adapter.commands.contains("ended(declined)") })
    finish(declined)

    // A call that is already missed when first seen never rang in the system, so there is nothing to end.
    let missed = await rig()
    _ = try await missed.client.demoMissedCall(kind: .direct)
    try #require(await waitUntil { missed.store.history.count == 1 })
    #expect(missed.adapter.commands.isEmpty)
    finish(missed)
  }

  @Test("Calls placed and answered while the app is open never reach CallKit")
  func foregroundCallsStayInApp() async throws {
    let rig = await rig(foreground: true)
    let conversation = try #require(try await MockChatClient().listConversations().first { $0.kind == .direct })
    await rig.store.startVideo(in: conversation.id)  // outgoing
    try #require(await waitUntil { rig.store.call?.state == .active })
    await rig.store.end()
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.store.call?.state == .incoming })
    await rig.store.answer()
    await rig.store.end()
    try await Task.sleep(for: .milliseconds(60))
    #expect(rig.adapter.commands.isEmpty)
    #expect(AudioSessionController.systemActivatesAudio == false)
    finish(rig)
  }

  @Test("With -callKitInApp every call is mirrored: incoming, answered, outgoing, connected, ended")
  func mirrorsInAppCallsWhenAsked() async throws {
    let rig = await rig(foreground: true, mirrorInApp: true)
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.store.call?.state == .incoming })
    await rig.store.answer()
    try #require(await waitUntil { rig.adapter.commands.contains("answered") })
    await rig.store.end()
    try #require(await waitUntil { rig.adapter.commands.contains("ended(remoteEnded)") })
    #expect(rig.adapter.commands.first?.hasPrefix("incoming(") == true)
    #expect(AudioSessionController.systemActivatesAudio == false)  // cleared once the call ended
    rig.store.dismiss()

    let conversation = try #require(try await MockChatClient().listConversations().first { $0.kind == .direct })
    await rig.store.startVideo(in: conversation.id)
    try #require(await waitUntil { rig.adapter.commands.contains("outgoingConnected") })
    #expect(rig.adapter.commands.contains { $0.hasPrefix("outgoingStarted(") })
    await rig.store.end()
    try #require(await waitUntil { rig.adapter.commands.filter { $0 == "ended(remoteEnded)" }.count == 2 })
    finish(rig)
  }

  @Test("A push is shown in the system UI even when the app is open, and audio then waits for CallKit")
  func pushIsReportedInForeground() async throws {
    let rig = await rig(pushWait: .seconds(30), foreground: true)
    rig.coordinator.handlePush(callID: "call-1", callerName: "Bob")
    #expect(rig.adapter.commands == ["incoming(Bob,video=true)"])
    #expect(AudioSessionController.systemActivatesAudio == true)
    finish(rig)
    #expect(AudioSessionController.systemActivatesAudio == false)
  }

  @Test("Answering from the system UI answers the call and is not echoed back to the system")
  func systemAnswer() async throws {
    let rig = await rig()
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.adapter.firstUUID != nil && rig.store.call?.state == .incoming })
    rig.adapter.user(.answer(try #require(rig.adapter.firstUUID)))
    try #require(await waitUntil { rig.store.call?.state == .active })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!rig.adapter.commands.contains("answered"))
    finish(rig)
  }

  @Test("Ending from the system UI declines a ringing call and ends a live one")
  func systemEnd() async throws {
    let ringing = await rig()
    _ = try await ringing.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { ringing.adapter.firstUUID != nil && ringing.store.call?.state == .incoming })
    ringing.adapter.user(.end(try #require(ringing.adapter.firstUUID)))
    try #require(await waitUntil { ringing.store.call?.state == .declined })
    finish(ringing)

    let live = await rig()
    _ = try await live.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { live.store.call?.state == .incoming })
    await live.store.answer()
    live.adapter.user(.end(try #require(live.adapter.firstUUID)))
    try #require(await waitUntil { live.store.call?.state == .ended })
    finish(live)
  }

  @Test("The system mute control toggles the microphone only when it disagrees with the call")
  func mute() async throws {
    let rig = await rig()
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.store.call?.state == .incoming })
    await rig.store.answer()
    let uuid = try #require(rig.adapter.firstUUID)
    rig.adapter.user(.setMuted(uuid, true))
    try #require(await waitUntil { rig.store.call?.microphoneEnabled == false })
    rig.adapter.user(.setMuted(uuid, true))  // already muted: nothing to do
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.store.call?.microphoneEnabled == false)
    rig.adapter.user(.setMuted(uuid, false))
    try #require(await waitUntil { rig.store.call?.microphoneEnabled == true })
    finish(rig)
  }

  @Test("A push is reported to the system immediately and not twice when the poll finds the call")
  func pushReportedFirst() async throws {
    let rig = await rig(pushWait: .seconds(30))
    rig.coordinator.handlePush(callID: "call-1", callerName: "Bob")
    #expect(rig.adapter.commands == ["incoming(Bob,video=true)"])
    rig.coordinator.handlePush(callID: "call-1", callerName: "Bob")  // a duplicate push
    #expect(rig.adapter.commands.count == 1)
    finish(rig)
  }

  @Test("A push whose call never shows up is ended as unanswered; a missing payload still reports a call")
  func pushWithoutCall() async throws {
    let rig = await rig(pushWait: .milliseconds(80))
    rig.coordinator.handlePush(callID: nil, callerName: nil)
    #expect(rig.adapter.commands == ["incoming(Incoming call,video=true)"])
    try #require(await waitUntil { rig.adapter.commands.contains("ended(unanswered)") })
    finish(rig)
  }

  @Test("Reset ends every call the system still shows")
  func resetEndsSystemCalls() async throws {
    let rig = await rig()
    _ = try await rig.client.demoIncomingCall(kind: .direct)
    try #require(await waitUntil { rig.adapter.commands.count >= 1 })
    rig.coordinator.reset()
    #expect(rig.adapter.commands.contains("ended(remoteEnded)"))
    rig.store.reset()
  }
}
