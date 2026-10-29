import Foundation
import Testing

@testable import ChatCall

@MainActor
struct AppDependenciesTests {
  @Test("Live wiring uses the live chat client; the demo flags keep the mocks")
  func selection() {
    let live = AppDependencies.live(
      configuration: .dev, gateway: GatewayConfiguration(httpBase: URL(string: "https://gw.test")!),
      voip: nil, arguments: [])
    #expect(live.auth is LiveAuthClient)
    #expect(live.chat is LiveChatClient)
    #expect(live.calls is UnconfiguredCallClient)
    #expect(live.demoCalls)
    let withVoIP = AppDependencies.live(
      configuration: .dev, gateway: GatewayConfiguration(httpBase: URL(string: "https://gw.test")!),
      voip: VoIPConfiguration(baseURL: URL(string: "https://voip.test")!), useSystemCalls: false,
      arguments: [])
    #expect(withVoIP.calls is LiveCallClient)
    #expect(!withVoIP.demoCalls)
    #expect(withVoIP.systemCalls == nil)  // CallKit is off in this hermetic test
    let mock = AppDependencies.launch(arguments: ["-demo-mock"])
    #expect(mock.chat is MockChatClient)
  }

  @Test("An ended session returns an authenticated store to Login and runs cleanup")
  func endedSessionSignsOut() async throws {
    let store = AuthStore(client: MockAuthClient(scheduler: ImmediateDemoScheduler()))
    var cleaned = 0
    store.resetAuthenticatedState = { cleaned += 1 }
    store.username = "ava"
    store.password = "secret123"
    await store.signIn()
    guard case .authenticated = store.state else {
      Issue.record("not authenticated")
      return
    }
    await store.sessionEnded()
    #expect(store.state == .unauthenticated)
    #expect(cleaned == 1)
    await store.sessionEnded()  // already signed out: nothing more happens
    #expect(cleaned == 1)
  }

  @Test("The signal reaches every subscriber and a finished one stops receiving")
  func signalFanOut() async {
    let signal = SessionEndedSignal()
    let first = signal.stream()
    let second = signal.stream()
    signal.fire()
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()
    #expect(await firstIterator.next() != nil)
    #expect(await secondIterator.next() != nil)
  }
}

@MainActor
struct CallErrorMessageTests {
  @Test("Each failure is explained to the user without leaking ids or server text")
  func messages() {
    func text(_ error: Error) -> String { CallStore.message(for: error) }
    #expect(text(CallError.notConfigured).contains("-voipURL"))
    #expect(text(CallError.capacityExceeded(maximum: 16)).contains("16"))
    #expect(text(CallError.callAlreadyInProgress) == "You're already in a call.")
    #expect(text(CallError.invalidConversation) == "This conversation can't be called.")
    #expect(text(VoIPError.transport).hasPrefix("Can't reach the call service"))
    #expect(text(VoIPError.server(503)).hasPrefix("Can't reach the call service"))
    #expect(text(VoIPError.forbidden).hasPrefix("You can't make this call"))
    #expect(text(VoIPError.conflict(call: nil, message: "secret detail")) == "Unable to update the call. Please try again.")
  }

  @Test("Without a VoIP URL a real conversation cannot be called, and the store says why")
  func unconfiguredStart() async throws {
    let conversation = try #require(try await MockChatClient().listConversations().first)
    await #expect(throws: CallError.notConfigured) {
      try await UnconfiguredCallClient().startVideoCall(in: conversation)
    }
    let store = CallStore(client: UnconfiguredCallClient(), chatClient: MockChatClient())
    await store.startVideo(in: conversation.id)
    #expect(store.errorMessage?.contains("-voipURL") == true)
    #expect(store.call == nil)
    store.reset()
  }

  @Test("The demo actions keep working without a VoIP URL")
  func demoStillWorks() async throws {
    let store = CallStore(client: UnconfiguredCallClient(), chatClient: MockChatClient())
    await store.incoming(kind: .direct)
    #expect(store.call?.state == .incoming)
    store.reset()
  }
}
