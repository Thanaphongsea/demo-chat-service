import Testing

@testable import ChatCall

struct ProjectSmokeTests {
  @Test("A fresh app root requires sign-in before entering the app")
  @MainActor
  func freshRootStartsAtUnauthenticatedGate() {
    #expect(AppRootView().gate == .unauthenticated)
  }
}
