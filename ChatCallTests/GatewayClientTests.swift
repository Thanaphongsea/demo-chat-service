import Foundation
import Testing

@testable import ChatCall

private actor StubTokens: AccessTokenProvider {
  private var queue: [Result<AccessToken, AuthError>]
  private(set) var invalidated: [String] = []
  private(set) var issued = 0

  init(_ queue: [Result<AccessToken, AuthError>] = []) { self.queue = queue }

  func validToken() async throws -> AccessToken {
    issued += 1
    if queue.count > 1 { return try queue.removeFirst().get() }
    return try (queue.first ?? .success(AccessToken(value: "T", expiresAt: .distantFuture))).get()
  }

  func invalidate(_ token: AccessToken) { invalidated.append(token.value) }
}

private nonisolated struct Ping: Encodable, Sendable { let From_Account = "alice" }
private nonisolated struct Pong: Decodable, Sendable, Equatable { let MsgKey: String }

private actor Sleeps {
  private(set) var values: [Duration] = []
  func record(_ duration: Duration) { values.append(duration) }
}

nonisolated struct GatewayClientTests {
  private static let configuration = GatewayConfiguration(
    httpBase: URL(string: "https://gw.example.test")!)

  private func client(
    tokens: StubTokens = StubTokens(), sleeps: Sleeps = Sleeps(),
    _ handler: @escaping @Sendable (URLRequest) async throws -> StubReply
  ) -> (GatewayClient, StubTransport) {
    let transport = StubTransport(reply: handler)
    return (
      GatewayClient(
        configuration: Self.configuration, tokens: tokens, transport: transport,
        sleep: { await sleeps.record($0) }),
      transport
    )
  }

  private func post(_ client: GatewayClient) async throws -> Pong {
    try await client.post("openim/sendmsg", body: Ping())
  }

  @Test("Builds an authorised JSON POST to /v4/<operation>")
  func buildsRequest() async throws {
    let (client, transport) = client { _ in .gateway(json: #"{"ErrorCode":0,"MsgKey":"k1"}"#) }
    let pong = try await post(client)
    #expect(pong == Pong(MsgKey: "k1"))
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://gw.example.test/v4/openim/sendmsg")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(String(data: try #require(request.httpBody), encoding: .utf8) == #"{"From_Account":"alice"}"#)
  }

  @Test("HTTP 200 with a non-zero ErrorCode throws the envelope, never decodes as success")
  func envelopeErrorOn200() async {
    let (client, transport) = client { _ in
      .gateway(json: #"{"ErrorCode":93000,"ErrorInfo":"bad","MsgKey":"k1"}"#)
    }
    await #expect(throws: GatewayError.envelope(code: 93000, info: "bad")) { try await post(client) }
    #expect(transport.requests.count == 1)
  }

  @Test("A retryable ErrorCode is re-posted with the same body")
  func retryableEnvelope() async throws {
    let calls = Counter()
    let (client, transport) = client { _ in
      await calls.next() == 1
        ? .gateway(json: #"{"ErrorCode":91000}"#) : .gateway(json: #"{"ErrorCode":0,"MsgKey":"k2"}"#)
    }
    #expect(try await post(client) == Pong(MsgKey: "k2"))
    #expect(transport.requests.count == 2)
    #expect(transport.requests[0].httpBody == transport.requests[1].httpBody)
  }

  @Test("A response without X-Request-Id did not pass the gateway and is not retried")
  func missingRequestID() async {
    let (client, transport) = client { _ in StubReply(200, Data(#"{"MsgKey":"k"}"#.utf8)) }
    await #expect(throws: GatewayError.missingRequestID) { try await post(client) }
    #expect(transport.requests.count == 1)
  }

  @Test("429 then 200 retries after a bounded backoff; Retry-After is honoured")
  func rateLimitedThenOK() async throws {
    let calls = Counter()
    let sleeps = Sleeps()
    let (client, transport) = client(sleeps: sleeps) { _ in
      switch await calls.next() {
      case 1: .gateway(429, headers: ["Retry-After": "2"])
      case 2: .gateway(429)
      default: .gateway(json: #"{"MsgKey":"k3"}"#)
      }
    }
    #expect(try await post(client) == Pong(MsgKey: "k3"))
    #expect(transport.requests.count == 3)
    let waits = await sleeps.values
    #expect(waits[0] == .seconds(2))
    #expect(waits[1] >= .milliseconds(500) && waits[1] <= .seconds(30))
  }

  @Test("503 gives up after five retries and surfaces the status")
  func serverErrorExhausts() async {
    let sleeps = Sleeps()
    let (client, transport) = client(sleeps: sleeps) { _ in .gateway(503) }
    await #expect(throws: GatewayError.server(503)) { try await post(client) }
    #expect(transport.requests.count == 6)
    #expect(await sleeps.values.allSatisfy { $0 <= .seconds(30) })
  }

  @Test("A transport failure is retried, then reported as transport")
  func transportFailure() async {
    let (client, transport) = client { _ in throw URLError(.notConnectedToInternet) }
    await #expect(throws: GatewayError.transport) { try await post(client) }
    #expect(transport.requests.count == 6)
  }

  @Test("401 with an expiry code invalidates the token and retries exactly once")
  func unauthorizedRefreshesOnce() async throws {
    let tokens = StubTokens([
      .success(AccessToken(value: "old", expiresAt: .distantFuture)),
      .success(AccessToken(value: "new", expiresAt: .distantFuture))
    ])
    let calls = Counter()
    let (client, transport) = client(tokens: tokens) { _ in
      await calls.next() == 1
        ? .gateway(401, json: #"{"ErrorCode":70001}"#) : .gateway(json: #"{"MsgKey":"k4"}"#)
    }
    #expect(try await post(client) == Pong(MsgKey: "k4"))
    #expect(await tokens.invalidated == ["old"])
    #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
  }

  @Test("A second 401 is unauthorized")
  func secondUnauthorized() async {
    let (client, transport) = client { _ in .gateway(401, json: #"{"ErrorCode":70001}"#) }
    await #expect(throws: GatewayError.unauthorized) { try await post(client) }
    #expect(transport.requests.count == 2)
  }

  @Test("401 with code 70009 is revoked: no refresh, no retry")
  func revoked() async {
    let tokens = StubTokens()
    let (client, transport) = client(tokens: tokens) { _ in
      .gateway(401, json: #"{"ErrorCode":70009}"#)
    }
    await #expect(throws: GatewayError.revoked) { try await post(client) }
    #expect(transport.requests.count == 1)
    #expect(await tokens.invalidated.isEmpty)
  }

  @Test("A token provider that cannot supply a token maps to a gateway error without a request")
  func tokenProviderFailures() async {
    for (failure, expected) in [
      (AuthError.invalidCredentials, GatewayError.unauthorized),
      (.revoked, .revoked), (.unavailable, .transport)
    ] {
      let (client, transport) = client(tokens: StubTokens([.failure(failure)])) { _ in .gateway() }
      await #expect(throws: expected) { try await post(client) }
      #expect(transport.requests.isEmpty)
    }
  }

  @Test("403 is forbidden and never retried")
  func forbidden() async {
    let (client, transport) = client { _ in .gateway(403) }
    await #expect(throws: GatewayError.forbidden) { try await post(client) }
    #expect(transport.requests.count == 1)
  }

  @Test("Cancellation propagates as CancellationError, not a service failure")
  func cancellation() async {
    let (cancelled, _) = client { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) { try await post(cancelled) }
    let (urlCancelled, _) = client { _ in throw URLError(.cancelled) }
    await #expect(throws: CancellationError.self) { try await post(urlCancelled) }
  }

  @Test("Errors never expose the bearer token")
  func errorsDoNotLeakToken() {
    #expect(!String(describing: GatewayError.unauthorized).contains("Bearer"))
    #expect(!String(describing: AccessToken(value: "secret-token", expiresAt: .now)).contains("secret-token"))
  }

  @Test("Configuration derives the websocket URL and accepts valid launch overrides only")
  func configuration() throws {
    #expect(Self.configuration.websocketURL.absoluteString == "wss://gw.example.test/ws/connection/websocket")
    #expect(
      GatewayConfiguration(httpBase: URL(string: "http://127.0.0.1:9080")!).websocketURL.absoluteString
        == "ws://127.0.0.1:9080/ws/connection/websocket")
    let suite = "GatewayClientTests.config"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(GatewayConfiguration(defaults: defaults) == .dev)
    defaults.set("ftp://bad", forKey: "gatewayURL")
    #expect(GatewayConfiguration(defaults: defaults) == .dev)
    defaults.set("https://gw.example.test", forKey: "gatewayURL")
    #expect(GatewayConfiguration(defaults: defaults).httpBase.absoluteString == "https://gw.example.test")
  }
}

private actor Counter {
  private var value = 0
  func next() -> Int {
    value += 1
    return value
  }
}
