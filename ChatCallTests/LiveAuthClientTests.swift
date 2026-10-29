import Foundation
import Testing

@testable import ChatCall

private nonisolated final class StubTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  let handler: @Sendable (URLRequest) async throws -> (Int, Data)
  init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
    self.handler = handler
  }
  var requests: [URLRequest] { lock.withLock { recorded } }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    let (status, data) = try await handler(request)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (data, response)
  }
}

nonisolated struct LiveAuthClientTests {
  private static let configuration = AuthConfiguration(
    baseURL: URL(string: "https://auth.example.test")!, appID: "1400000000")
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func jwt(sub: String) -> String {
    let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "h.\(payload).s"
  }

  private static func ok(sub: String = "u_alice", expires: String = "2027-01-15T09:00:00Z") -> (
    Int, Data
  ) {
    (200, Data(#"{"token":"\#(jwt(sub: sub))","expires_at":"\#(expires)"}"#.utf8))
  }

  private func client(
    store: InMemorySessionStore = InMemorySessionStore(),
    _ handler: @escaping @Sendable (URLRequest) async throws -> (Int, Data)
  ) -> (LiveAuthClient, StubTransport) {
    let transport = StubTransport(handler)
    return (
      LiveAuthClient(
        configuration: Self.configuration, transport: transport, store: store,
        deviceID: "ios-test-device", now: { Self.now }),
      transport
    )
  }

  @Test("Posts the credentials and app id to /v1/token and keeps the token")
  func signInSuccess() async throws {
    let store = InMemorySessionStore()
    let (client, transport) = client(store: store) { _ in Self.ok() }
    let session = try await client.signIn(
      credentials: Credentials(identity: " u_alice ", password: "secret123"))
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://auth.example.test/v1/token")
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(
      json == [
        "user_id": "u_alice", "app_id": "1400000000", "password": "secret123",
        "device_id": "ios-test-device"
      ])
    #expect(session.user.id == UserID("u_alice"))
    #expect(
      session.accessToken?.expiresAt == ISO8601DateFormatter().date(from: "2027-01-15T09:00:00Z"))
    #expect(session.accessToken?.value == Self.jwt(sub: "u_alice"))
    #expect(await client.currentSession == session)
    #expect(store.load() == session)
  }

  @Test("401 maps to invalid credentials and stores nothing")
  func unauthorized() async {
    let store = InMemorySessionStore()
    let (client, _) = client(store: store) { _ in
      (401, Data(#"{"error":"invalid credentials"}"#.utf8))
    }
    await #expect(throws: AuthError.invalidCredentials) {
      try await client.signIn(credentials: Credentials(identity: "u_alice", password: "bad"))
    }
    #expect(await client.currentSession == nil)
    #expect(store.load() == nil)
  }

  @Test("Rate limits, server errors, and transport failures are unavailable, not bad credentials")
  func unavailable() async {
    for status in [429, 500, 503] {
      let (client, _) = client { _ in (status, Data()) }
      await #expect(throws: AuthError.unavailable) {
        try await client.signIn(credentials: Credentials(identity: "a", password: "secret123"))
      }
    }
    let (offline, _) = client { _ in throw URLError(.notConnectedToInternet) }
    await #expect(throws: AuthError.unavailable) {
      try await offline.signIn(credentials: Credentials(identity: "a", password: "secret123"))
    }
  }

  @Test("A malformed success body is an invalid response")
  func malformed() async {
    let (client, _) = client { _ in (200, Data("{}".utf8)) }
    await #expect(throws: AuthError.invalidResponse) {
      try await client.signIn(credentials: Credentials(identity: "a", password: "secret123"))
    }
  }

  @Test("Sign-out clears memory and store; an expired stored session is dropped")
  func signOutAndExpiry() async throws {
    let store = InMemorySessionStore()
    let (client, _) = client(store: store) { _ in Self.ok() }
    _ = try await client.signIn(
      credentials: Credentials(identity: "u_alice", password: "secret123"))
    await client.signOut()
    #expect(await client.currentSession == nil)
    #expect(store.load() == nil)

    store.save(
      Session(
        user: User(id: UserID("u_alice"), displayName: "u_alice", initials: "U_"),
        signedInAt: Self.now,
        accessToken: AccessToken(value: "t", expiresAt: Self.now.addingTimeInterval(-1))))
    #expect(await client.currentSession == nil)
    #expect(store.load() == nil)
  }

  @Test("Sign-out while the request is in flight prevents the late token from committing")
  func signOutDuringRequest() async throws {
    let store = InMemorySessionStore()
    let gate = AsyncStream<Void>.makeStream()
    let (client, transport) = client(store: store) { _ in
      for await _ in gate.stream { break }
      return Self.ok()
    }
    let task = Task {
      try await client.signIn(credentials: Credentials(identity: "u_alice", password: "secret123"))
    }
    while transport.requests.isEmpty { await Task.yield() }
    await client.signOut()
    gate.continuation.yield()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.currentSession == nil)
    #expect(store.load() == nil)
  }

  // MARK: token lifecycle

  private func signedInClient(
    store: InMemorySessionStore = InMemorySessionStore(), expires: String,
    refresh: @escaping @Sendable (URLRequest) async throws -> (Int, Data)
  ) async throws -> (LiveAuthClient, StubTransport) {
    let (client, transport) = client(store: store) { request in
      request.url?.path == "/v1/token" ? Self.ok(expires: expires) : try await refresh(request)
    }
    _ = try await client.signIn(
      credentials: Credentials(identity: "u_alice", password: "secret123"))
    return (client, transport)
  }

  private static func refreshed(_ token: String = "new-token") -> (Int, Data) {
    (200, Data(#"{"token":"\#(token)","expires_at":"2027-01-15T10:00:00Z"}"#.utf8))
  }

  // `now` is 2027-01-15T08:00:00Z.
  @Test("A token within 60 seconds of expiry is refreshed with the old token as bearer")
  func refreshesNearExpiry() async throws {
    let store = InMemorySessionStore()
    let (client, transport) = try await signedInClient(
      store: store, expires: "2027-01-15T08:00:30Z"
    ) { _ in Self.refreshed() }
    let old = Self.jwt(sub: "u_alice")
    let token = try await client.validToken()
    let request = try #require(transport.requests.last)
    #expect(request.url?.path == "/v1/token/refresh")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(old)")
    #expect(token.value == "new-token")
    #expect(await client.currentSession?.accessToken?.value == "new-token")
    #expect(store.load()?.accessToken?.value == "new-token")
  }

  @Test("A fresh token is returned without a request")
  func freshTokenNoRequest() async throws {
    let (client, transport) = try await signedInClient(expires: "2027-01-15T08:10:00Z") { _ in
      Self.refreshed()
    }
    let token = try await client.validToken()
    #expect(token.value == Self.jwt(sub: "u_alice"))
    #expect(transport.requests.count == 1)
  }

  @Test("Concurrent callers share a single refresh request")
  func concurrentRefreshShared() async throws {
    let gate = AsyncStream<Void>.makeStream()
    let (client, transport) = try await signedInClient(expires: "2027-01-15T08:00:30Z") { _ in
      for await _ in gate.stream { break }
      return Self.refreshed()
    }
    async let first = client.validToken()
    async let second = client.validToken()
    while transport.requests.count < 2 { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }
    gate.continuation.yield()
    let tokens = try await [first, second]
    #expect(tokens.map(\.value) == ["new-token", "new-token"])
    #expect(transport.requests.filter { $0.url?.path == "/v1/token/refresh" }.count == 1)
  }

  @Test("A rejected token is refreshed on the next request even when it looks fresh")
  func invalidateForcesRefresh() async throws {
    let (client, transport) = try await signedInClient(expires: "2027-01-15T08:10:00Z") { _ in
      Self.refreshed()
    }
    let first = try await client.validToken()
    await client.invalidate(first)
    #expect(try await client.validToken().value == "new-token")
    #expect(transport.requests.count == 2)
  }

  @Test("Refresh 401 with code 70009 is revoked: session cleared, never retried")
  func refreshRevoked() async throws {
    let store = InMemorySessionStore()
    let (client, transport) = try await signedInClient(
      store: store, expires: "2027-01-15T08:00:30Z"
    ) { _ in (401, Data(#"{"ErrorCode":70009}"#.utf8)) }
    await #expect(throws: AuthError.revoked) { try await client.validToken() }
    #expect(await client.currentSession == nil)
    #expect(store.load() == nil)
    await #expect(throws: AuthError.invalidCredentials) { try await client.validToken() }
    #expect(transport.requests.filter { $0.url?.path == "/v1/token/refresh" }.count == 1)
  }

  @Test("Refresh 401 with another code (either field spelling) ends the session")
  func refreshExpired() async throws {
    for body in [#"{"ErrorCode":70001}"#, #"{"code":70003}"#, "{}"] {
      let store = InMemorySessionStore()
      let (client, _) = try await signedInClient(
        store: store, expires: "2027-01-15T08:00:30Z"
      ) { _ in (401, Data(body.utf8)) }
      await #expect(throws: AuthError.invalidCredentials) { try await client.validToken() }
      #expect(await client.currentSession == nil)
      #expect(store.load() == nil)
    }
  }

  @Test("A server error during refresh keeps the session and reports unavailable")
  func refreshUnavailableKeepsSession() async throws {
    let (client, _) = try await signedInClient(expires: "2027-01-15T08:00:30Z") { _ in
      (503, Data())
    }
    await #expect(throws: AuthError.unavailable) { try await client.validToken() }
    #expect(await client.currentSession != nil)
  }

  @Test("Signed out, validToken asks for sign-in and makes no request")
  func validTokenWithoutSession() async {
    let (client, transport) = client { _ in Self.ok() }
    await #expect(throws: AuthError.invalidCredentials) { try await client.validToken() }
    #expect(transport.requests.isEmpty)
  }

  @Test("The device id is generated once and then reused")
  func deviceIdentifierIsStable() throws {
    let suite = "LiveAuthClientTests.device"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = DeviceIdentifier.current(defaults: defaults)
    #expect(first.hasPrefix("ios-"))
    #expect(DeviceIdentifier.current(defaults: defaults) == first)
  }

  @Test("Configuration defaults to dev and accepts valid launch overrides only")
  func configuration() throws {
    let suite = "LiveAuthClientTests.config"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AuthConfiguration(defaults: defaults) == .dev)
    defaults.set("ftp://bad", forKey: "authBaseURL")
    #expect(AuthConfiguration(defaults: defaults) == .dev)
    defaults.set("https://auth.example.test", forKey: "authBaseURL")
    defaults.set("42", forKey: "authAppID")
    let config = AuthConfiguration(defaults: defaults)
    #expect(config.baseURL.absoluteString == "https://auth.example.test")
    #expect(config.appID == "42")
  }

  @Test("Launch uses live auth by default and the mock for demo flags")
  func launchSelection() async throws {
    #expect(AppDependencies.launch(arguments: []).auth is LiveAuthClient)
    #expect(AppDependencies.launch(arguments: ["-demo-mock"]).auth is MockAuthClient)
    #expect(AppDependencies.launch(arguments: ["-demo-immediateEvents"]).auth is MockAuthClient)
  }
}
