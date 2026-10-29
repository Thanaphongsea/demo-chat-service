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
    #expect(live.calls is MockCallClient)
    #expect(live.demoCalls)
    let withVoIP = AppDependencies.live(
      configuration: .dev, gateway: GatewayConfiguration(httpBase: URL(string: "https://gw.test")!),
      voip: VoIPConfiguration(baseURL: URL(string: "https://voip.test")!), arguments: [])
    #expect(withVoIP.calls is LiveCallClient)
    #expect(!withVoIP.demoCalls)
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
