import Foundation
import Testing

@testable import ChatCall

private actor Counter {
  private var value = 0
  func next() -> Int {
    value += 1
    return value
  }
}

private actor StubTokens: AccessTokenProvider {
  private(set) var invalidated: [String] = []
  private var tokens: [String]
  init(_ tokens: [String] = ["T"]) { self.tokens = tokens }
  func validToken() async throws -> AccessToken {
    AccessToken(value: tokens.count > 1 ? tokens.removeFirst() : tokens[0], expiresAt: .distantFuture)
  }
  func invalidate(_ token: AccessToken) { invalidated.append(token.value) }
}

nonisolated struct VoIPClientTests {
  static let me = UserID("alice")
  static let callJSON = """
    {"call_id":"call-1","room_id":"grp_demo","caller_id":"alice","callee_id":"","caller_name":"Alice",
     "status":"accepted","group":true,"group_status":"accepted","can_join":true,
     "participants":[{"user_id":"alice","status":"joined","heartbeat_at":"2026-10-22T09:00:00Z"},
                     {"user_id":"bob","status":"invited"}],
     "push_sent":false,"created_at":"2026-10-22T09:00:00.123Z","updated_at":"2026-10-22T09:00:01Z"}
    """

  private func client(
    tokens: StubTokens = StubTokens(), sleeps: Sleeps = Sleeps(),
    _ handler: @escaping @Sendable (URLRequest) async throws -> StubReply
  ) -> (VoIPClient, StubTransport) {
    let transport = StubTransport(reply: handler)
    return (
      VoIPClient(
        configuration: VoIPConfiguration(baseURL: URL(string: "https://voip.example.test")!),
        tokens: tokens, transport: transport, sleep: { await sleeps.record($0) }), transport
    )
  }

  private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
  }

  private let groupCreate = CreateCallRequest(
    callerID: "alice", callerName: "Alice", roomID: "grp_demo", calleeID: nil,
    calleeIDs: ["bob", "carol"], idempotencyKey: "ios-key-1")

  @Test("Create posts the group payload with the key in the header and the body, and decodes the call")
  func createGroup() async throws {
    let (client, transport) = client { _ in StubReply(201, Data(Self.callJSON.utf8)) }
    let call = try await client.create(groupCreate)
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://voip.example.test/api/calls")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "ios-key-1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    let json = body(request)
    #expect(json["callee_ids"] as? [String] == ["bob", "carol"])
    #expect(json["callee_id"] == nil)
    #expect(json["idempotency_key"] as? String == "ios-key-1")
    #expect(json["caller_id"] as? String == "alice")
    #expect(json["room_id"] as? String == "grp_demo")
    #expect(call.callID == "call-1")
    #expect(call.canJoin == true)
    #expect(call.participants?.map(\.status) == ["joined", "invited"])
    #expect(WireDate.parse(call.createdAt) != nil)
  }

  @Test("A direct create sends callee_id and never callee_ids")
  func createDirect() async throws {
    let (client, transport) = client { _ in StubReply(201, Data(Self.callJSON.utf8)) }
    _ = try await client.create(
      CreateCallRequest(
        callerID: "alice", callerName: "Alice", roomID: "dm_alice_bob", calleeID: "bob",
        calleeIDs: nil, idempotencyKey: "k"))
    let json = body(try #require(transport.requests.first))
    #expect(json["callee_id"] as? String == "bob")
    #expect(json["callee_ids"] == nil)
  }

  @Test("Create retried after 503 or a transport failure repeats the same key and body")
  func createRetryKeepsKey() async throws {
    let calls = Counter()
    let (client, transport) = client { _ in
      switch await calls.next() {
      case 1: throw URLError(.timedOut)
      case 2: StubReply(503, Data(#"{"error":"busy"}"#.utf8))
      default: StubReply(201, Data(Self.callJSON.utf8))
      }
    }
    _ = try await client.create(groupCreate)
    #expect(transport.requests.count == 3)
    #expect(Set(transport.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }) == ["ios-key-1"])
    #expect(Set(transport.requests.compactMap(\.httpBody)).count == 1)
  }

  @Test("503 gives up after five retries")
  func serverErrorExhausts() async {
    let (client, transport) = client { _ in StubReply(503) }
    await #expect(throws: VoIPError.server(503)) { try await client.create(groupCreate) }
    #expect(transport.requests.count == 6)
  }

  @Test("Inbox and state reads carry peer_id; every action posts peer_id to its own path")
  func readsAndActions() async throws {
    let (client, transport) = client { request in
      request.url?.path == "/api/calls"
        ? StubReply(200, Data(#"{"calls":[],"joinable_calls":[\#(Self.callJSON)]}"#.utf8))
        : StubReply(200, Data(Self.callJSON.utf8))
    }
    let inbox = try await client.inbox(peer: Self.me)
    #expect(inbox.calls.isEmpty)
    #expect(inbox.joinableCalls.map(\.callID) == ["call-1"])
    _ = try await client.call(id: "call-1", peer: Self.me)
    for action in [CallAction.accept, .reject, .cancel, .join, .leave, .heartbeat, .end, .endAll] {
      _ = try await client.perform(action, id: "call-1", peer: Self.me)
    }
    let urls = transport.requests.map { $0.url!.absoluteString }
    #expect(urls[0] == "https://voip.example.test/api/calls?peer_id=alice")
    #expect(urls[1] == "https://voip.example.test/api/calls/call-1?peer_id=alice")
    #expect(
      urls.dropFirst(2).map { String($0.split(separator: "/").last!) }
        == ["accept", "reject", "cancel", "join", "leave", "heartbeat", "end", "end-all"])
    #expect(transport.requests.dropFirst(2).allSatisfy { body($0)["peer_id"] as? String == "alice" })
    #expect(transport.requests.dropFirst(2).allSatisfy { $0.httpMethod == "POST" })
  }

  @Test("An inbox missing a list decodes it as empty")
  func inboxToleratesMissingLists() async throws {
    let (client, _) = client { _ in StubReply(200, Data("{}".utf8)) }
    let inbox = try await client.inbox(peer: Self.me)
    #expect(inbox.calls.isEmpty && inbox.joinableCalls.isEmpty)
  }

  @Test("404 and 409 expose the call from the error body; 403, 400 and 429 map to typed errors")
  func errorMapping() async {
    let attached = #"{"error":"x","call":\#(Self.callJSON)}"#
    let (notFound, _) = client { _ in StubReply(404, Data(attached.utf8)) }
    await #expect(throws: VoIPError.self) { try await notFound.call(id: "c", peer: Self.me) }
    do { _ = try await notFound.call(id: "c", peer: Self.me) } catch let VoIPError.notFound(call) {
      #expect(call?.callID == "call-1")
    } catch { Issue.record("wrong error \(error)") }
    let (conflict, _) = client { _ in StubReply(409, Data(attached.utf8)) }
    do { _ = try await conflict.perform(.join, id: "c", peer: Self.me) } catch let VoIPError.conflict(call, message) {
      #expect(call?.callID == "call-1")
      #expect(message == "x")
    } catch { Issue.record("wrong error \(error)") }
    let (forbidden, _) = client { _ in StubReply(403) }
    await #expect(throws: VoIPError.forbidden) { try await forbidden.inbox(peer: Self.me) }
    let (bad, _) = client { _ in StubReply(400, Data(#"{"error":"nope"}"#.utf8)) }
    await #expect(throws: VoIPError.badRequest(message: "nope")) { try await bad.inbox(peer: Self.me) }
    let (limited, _) = client { _ in StubReply(429) }
    await #expect(throws: VoIPError.rateLimited) { try await limited.inbox(peer: Self.me) }
  }

  @Test("401 invalidates the token and retries once; a second 401 is unauthorized")
  func unauthorized() async throws {
    let tokens = StubTokens(["old", "new"])
    let calls = Counter()
    let (client, transport) = client(tokens: tokens) { _ in
      await calls.next() == 1 ? StubReply(401) : StubReply(200, Data(Self.callJSON.utf8))
    }
    _ = try await client.call(id: "call-1", peer: Self.me)
    #expect(await tokens.invalidated == ["old"])
    #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
    let (always, _) = self.client { _ in StubReply(401) }
    await #expect(throws: VoIPError.unauthorized) { try await always.inbox(peer: Self.me) }
  }

  @Test("A malformed success body is an invalid response; cancellation is not a service failure")
  func malformedAndCancelled() async {
    let (malformed, _) = client { _ in StubReply(200, Data("[]".utf8)) }
    await #expect(throws: VoIPError.invalidResponse) { try await malformed.call(id: "c", peer: Self.me) }
    let (cancelled, _) = client { _ in throw URLError(.cancelled) }
    await #expect(throws: CancellationError.self) { try await cancelled.inbox(peer: Self.me) }
  }

  @Test("Configuration exists only for an http(s) voipURL")
  func configuration() throws {
    let suite = "VoIPClientTests.config"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(VoIPConfiguration(defaults: defaults) == nil)
    defaults.set("ftp://x", forKey: "voipURL")
    #expect(VoIPConfiguration(defaults: defaults) == nil)
    defaults.set("https://voip.example.test", forKey: "voipURL")
    #expect(VoIPConfiguration(defaults: defaults)?.baseURL.absoluteString == "https://voip.example.test")
  }

  @Test("Prepare room posts the logical room id with the call id as a query")
  func prepareRoom() async throws {
    let (client, transport) = client { _ in StubReply(201, Data(#"{"room_id":"internal-1"}"#.utf8)) }
    try await client.prepareRoom(callID: "call-1", roomID: "grp_demo")
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://voip.example.test/api/rooms?call_id=call-1")
    #expect(request.httpMethod == "POST")
    #expect(body(request)["room_id"] as? String == "grp_demo")
  }

  @Test("ICE servers accept one url or many, and never print the credential")
  func iceServers() async throws {
    let json = """
      {"iceServers":[{"urls":"stun:stun.example.test:3478"},
       {"urls":["turn:turn.example.test:3478?transport=udp","turns:turn.example.test:443"],
        "username":"u","credential":"s3cret","credentialType":"password"}]}
      """
    let (client, transport) = client { _ in StubReply(200, Data(json.utf8)) }
    let servers = try await client.iceServers()
    #expect(transport.requests.first?.url?.path == "/api/ice")
    #expect(servers.map(\.urls.count) == [1, 2])
    #expect(servers[1].username == "u" && servers[1].credential == "s3cret")
    #expect(!String(describing: servers[1]).contains("s3cret"))
    #expect(!String(reflecting: servers[1]).contains("s3cret"))
  }

  @Test("The media socket URL carries room, peer and call but never the token")
  func mediaSocket() async throws {
    let (client, _) = client { _ in StubReply(200) }
    let socket = try await client.mediaSocket(roomID: "grp_demo", callID: "call-1", peer: Self.me)
    #expect(socket.url.absoluteString == "wss://voip.example.test/api/ws?room_id=grp_demo&peer_id=alice&call_id=call-1")
    #expect(socket.token == "T")
    #expect(!socket.url.absoluteString.contains("T&") && !socket.url.absoluteString.contains("token"))
  }
}


private actor Sleeps {
  private(set) var values: [Duration] = []
  func record(_ duration: Duration) { values.append(duration) }
}
