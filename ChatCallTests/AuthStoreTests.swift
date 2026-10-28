import Foundation
import Testing

@testable import ChatCall

@MainActor
struct AuthStoreTests {
  @Test(
    "Blank identities and short passwords never create a session",
    arguments: [
      Credentials(identity: " \n", password: "123456"),
      Credentials(identity: "alex", password: "12345")
    ])
  func localValidation(credentials: Credentials) async {
    let client = MockAuthClient()
    let store = AuthStore(client: client)
    store.username = credentials.identity
    store.password = credentials.password
    #expect(!store.canSignIn)
    await store.signIn()
    #expect(store.state == .unauthenticated)
    #expect(store.validationMessage != nil)
    #expect(await client.currentSession == nil)
  }

  @Test("A pending sign-in disables submission until its normalized session arrives")
  func loadingAndSuccess() async throws {
    let scheduler = ManualDemoScheduler()
    let store = filledStore(client: MockAuthClient(scheduler: scheduler))
    let request = Task { await store.signIn() }
    defer { request.cancel() }
    try #require(await scheduler.waitForPendingSleep())
    #expect(store.state == .signingIn)
    #expect(!store.canSignIn)
    await scheduler.advance()
    await request.value
    guard case .authenticated(let session) = store.state else {
      Issue.record("Successful credentials must enter the authenticated gate")
      return
    }
    #expect(session.user.displayName == "alex")
    #expect(session.user.id == UserID("user-me"))
    #expect(store.password.isEmpty)
  }

  @Test("Invalid credentials show a recoverable error and allow another attempt")
  func rejectedCredentialsCanRetry() async {
    let store = AuthStore(client: MockAuthClient())
    store.username = "invalid"
    store.password = "invalid"
    await store.signIn()
    #expect(store.state == .failed("The username or password is incorrect. Try again."))
    #expect(store.canSignIn)
    store.username = "alex"
    store.password = "123456"
    await store.signIn()
    guard case .authenticated = store.state else {
      Issue.record("Retrying corrected credentials must sign in")
      return
    }
  }

  @Test("Cancelling a pending submit returns to Login without a late session or error")
  func cancellation() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockAuthClient(scheduler: scheduler)
    let store = filledStore(client: client)
    let request = Task { await store.signIn() }
    defer { request.cancel() }
    try #require(await scheduler.waitForPendingSleep())
    request.cancel()
    await request.value
    await scheduler.advance()
    #expect(store.state == .unauthenticated)
    #expect(store.canSignIn)
    #expect(await client.currentSession == nil)
  }

  @Test("A duplicate submit cannot replace or invalidate the first pending attempt")
  func duplicateSubmit() async throws {
    let scheduler = ManualDemoScheduler()
    let store = filledStore(client: MockAuthClient(scheduler: scheduler))
    let first = Task { await store.signIn() }
    defer { first.cancel() }
    try #require(await scheduler.waitForPendingSleep())
    store.username = "different"
    await store.signIn()
    await scheduler.advance()
    await first.value
    guard case .authenticated(let session) = store.state else {
      Issue.record("A duplicate must not invalidate the original sign-in")
      return
    }
    #expect(session.user.displayName == "alex")
  }

  @Test("Logout clears credentials and client session and runs cleanup before Login")
  func logoutReset() async {
    let client = MockAuthClient()
    var cleanupStates: [AuthStore.State] = []
    let store = filledStore(client: client)
    store.resetAuthenticatedState = { [weak store] in
      if let store { cleanupStates.append(store.state) }
    }
    await store.signIn()
    await store.signOut()
    #expect(store.state == .unauthenticated)
    #expect(store.username.isEmpty)
    #expect(store.password.isEmpty)
    #expect(await client.currentSession == nil)
    #expect(cleanupStates == [.signingOut])
  }

  @Test("Logging out during sign-in cancels pending work and rejects late authentication")
  func logoutDuringSignIn() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockAuthClient(scheduler: scheduler)
    let store = filledStore(client: client)
    let request = Task { await store.signIn() }
    defer { request.cancel() }
    try #require(await scheduler.waitForPendingSleep())
    await store.signOut()
    await scheduler.advance()
    await request.value
    #expect(store.state == .unauthenticated)
    #expect(store.username.isEmpty)
    #expect(await client.currentSession == nil)
  }

  @Test(
    "An old client response cannot overwrite a newer authenticated session after logout",
    arguments: [false, true])
  func lateResponseAfterNewSession(cancelCaller: Bool) async throws {
    let client = DeferredAuthClient()
    let store = filledStore(client: client)
    let oldRequest = Task { await store.signIn() }
    try #require(await client.waitForRequest("alex"))
    if cancelCaller { oldRequest.cancel() }
    await store.signOut()
    store.username = "new-user"
    store.password = "123456"
    let newRequest = Task { await store.signIn() }
    try #require(await client.waitForRequest("new-user"))
    await client.complete("new-user")
    await newRequest.value
    await client.complete("alex")
    await oldRequest.value
    guard case .authenticated(let session) = store.state else {
      Issue.record("The old cancelled request must not reset the newer session")
      return
    }
    #expect(session.user.displayName == "new-user")
  }

  private func filledStore(client: any AuthClient) -> AuthStore {
    let store = AuthStore(client: client)
    store.username = " alex "
    store.password = "123456"
    return store
  }
}

// Models a backend that returns a response even after its caller cancels.
private actor DeferredAuthClient: AuthClient {
  var currentSession: Session? { nil }
  private var requests: [String: CheckedContinuation<Session, any Error>] = [:]

  func signIn(credentials: Credentials) async throws -> Session {
    try await withCheckedThrowingContinuation { requests[credentials.identity] = $0 }
  }

  func signOut() async {}

  func waitForRequest(_ identity: String) async -> Bool {
    for _ in 0..<10_000 {
      if requests[identity] != nil { return true }
      await Task.yield()
    }
    return false
  }

  func complete(_ identity: String) {
    requests.removeValue(forKey: identity)?.resume(
      returning: Session(
        user: User(id: UserID("user-me"), displayName: identity, initials: "ME"),
        signedInAt: Date(timeIntervalSince1970: 1_700_000_000)))
  }
}
