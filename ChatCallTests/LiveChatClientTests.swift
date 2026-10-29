import Foundation
import Testing

@testable import ChatCall

nonisolated struct LiveChatClientTests {
  static let me = UserID("alice")

  /// Routes by operation (`/v4/<operation>`); the handler returns the JSON body of an HTTP 200.
  static func harness(
    user: UserID? = me,
    _ handler: @escaping @Sendable (_ operation: String, _ body: [String: Any]) async throws -> String
  ) -> (LiveChatClient, StubTransport) {
    let transport = StubTransport(reply: { request in
      let operation = String(request.url!.path.dropFirst("/v4/".count))
      let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
      return .gateway(json: try await handler(operation, body ?? [:]))
    })
    let gateway = GatewayClient(
      configuration: GatewayConfiguration(httpBase: URL(string: "https://gw.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    return (LiveChatClient(gateway: gateway, currentUser: { user }), transport)
  }

  static func bodies(_ transport: StubTransport, _ operation: String) -> [[String: Any]] {
    transport.requests.filter { $0.url?.path == "/v4/\(operation)" }.compactMap {
      (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any]
    }
  }

  static func text(_ key: String, from: String, seconds: Int, text: String = "hi") -> String {
    """
    {"MsgKey":"\(key)","From_Account":"\(from)","MsgTimeStamp":\(seconds),
     "MsgBody":[{"MsgType":"TIMTextElem","MsgContent":{"Text":"\(text)"}}]}
    """
  }

  static func directRow(_ peer: String, time: Int, unread: Int = 0) -> String {
    """
    {"Type":1,"To_Account":"\(peer)","conversationID":"c2c_\(peer)","showName":"\(peer)",
     "unreadCount":\(unread),"MsgTime":\(time),"lastMessage":\(text("k-\(peer)", from: peer, seconds: time))}
    """
  }

  static func groupRow(_ id: String, time: Int) -> String {
    #"{"Type":2,"GroupId":"\#(id)","conversationID":"group_\#(id)","showName":"Team \#(id)","MsgTime":\#(time)}"#
  }

  static func members(_ accounts: [String]) -> String {
    accounts.map { #"{"Member_Account":"\#($0)"}"# }.joined(separator: ",")
  }

  // MARK: listConversations

  @Test("Reads the pinned and normal cursors until the server reports both complete")
  func listPagesUntilComplete() async throws {
    let (client, transport) = Self.harness { operation, body in
      guard operation == "recentcontact/get_list" else { return "{}" }
      if (body["TimeStamp"] as? Double ?? 0) == 0 {
        return """
          {"ErrorCode":0,"SessionItem":[\(Self.directRow("bob", time: 100))],
           "CompleteFlag":0,"TimeStamp":100,"StartIndex":1,"TopTimeStamp":7,"TopStartIndex":2}
          """
      }
      return """
        {"ErrorCode":0,"SessionItem":[\(Self.directRow("carol", time: 200))],"CompleteFlag":3}
        """
    }
    let conversations = try await client.listConversations()
    #expect(conversations.map(\.id.rawValue) == ["c2c_carol", "c2c_bob"])
    let requests = Self.bodies(transport, "recentcontact/get_list")
    #expect(requests.count == 2)
    #expect(requests[0]["From_Account"] as? String == "alice")
    #expect(requests[0]["AssistFlags"] as? Int == 63)
    #expect(requests[1]["TimeStamp"] as? Int == 100)
    #expect(requests[1]["StartIndex"] as? Int == 1)
    #expect(requests[1]["TopTimeStamp"] as? Int == 7)
    #expect(requests[1]["TopStartIndex"] as? Int == 2)
  }

  @Test("A duplicate row collapses; an empty list is a valid result")
  func listDeduplicatesAndAllowsEmpty() async throws {
    let (client, _) = Self.harness { _, _ in
      """
      {"ErrorCode":0,"CompleteFlag":3,
       "SessionItem":[\(Self.directRow("bob", time: 1)),\(Self.directRow("bob", time: 1))]}
      """
    }
    #expect(try await client.listConversations().count == 1)
    let (empty, _) = Self.harness { _, _ in #"{"ErrorCode":0,"CompleteFlag":3}"# }
    #expect(try await empty.listConversations().isEmpty)
  }

  @Test("A group's roster is read page by page until complete")
  func rosterIsComplete() async throws {
    let everyone = (0..<150).map { "u\($0)" }
    let (client, transport) = Self.harness { operation, body in
      switch operation {
      case "recentcontact/get_list":
        return #"{"ErrorCode":0,"CompleteFlag":3,"SessionItem":[\#(Self.groupRow("g1", time: 5))]}"#
      case "group_open_http_svc/get_group_member_info":
        let offset = body["Offset"] as? Int ?? 0
        let page = Array(everyone[offset..<min(offset + 100, everyone.count)])
        return #"{"ErrorCode":0,"MemberNum":150,"MemberList":[\#(Self.members(page))]}"#
      default: return "{}"
      }
    }
    let conversation = try #require(try await client.listConversations().first)
    #expect(conversation.kind == .group)
    #expect(conversation.memberIDs.count == 151)  // 150 members plus me
    let pages = Self.bodies(transport, "group_open_http_svc/get_group_member_info")
    #expect(pages.map { $0["Offset"] as? Int } == [0, 100])
    #expect(pages.allSatisfy { $0["Limit"] as? Int == 100 && $0["GroupId"] as? String == "g1" })
  }

  @Test("A roster that stays short of MemberNum throws instead of being returned as complete")
  func shortRosterThrows() async {
    let (client, _) = Self.harness { operation, _ in
      operation == "recentcontact/get_list"
        ? #"{"ErrorCode":0,"CompleteFlag":3,"SessionItem":[\#(Self.groupRow("g1", time: 5))]}"#
        : #"{"ErrorCode":0,"MemberNum":3,"MemberList":[\#(Self.members(["bob", "carol"]))]}"#
    }
    await #expect(throws: GatewayError.invalidResponse) { try await client.listConversations() }
  }

  @Test("A failed roster page fails the list")
  func rosterFailureThrows() async {
    let (client, _) = Self.harness { operation, _ in
      operation == "recentcontact/get_list"
        ? #"{"ErrorCode":0,"CompleteFlag":3,"SessionItem":[\#(Self.groupRow("g1", time: 5))]}"#
        : #"{"ErrorCode":10007,"ErrorInfo":"no"}"#
    }
    await #expect(throws: GatewayError.envelope(code: 10007, info: "no")) {
      try await client.listConversations()
    }
  }

  @Test("Envelope errors, a signed-out user and cancellation are reported distinctly")
  func listFailures() async {
    let (failing, _) = Self.harness { _, _ in #"{"ErrorCode":93000,"ErrorInfo":"bad"}"# }
    await #expect(throws: GatewayError.envelope(code: 93000, info: "bad")) {
      try await failing.listConversations()
    }
    let (signedOut, transport) = Self.harness(user: nil) { _, _ in "{}" }
    await #expect(throws: GatewayError.unauthorized) { try await signedOut.listConversations() }
    #expect(transport.requests.isEmpty)
    let (cancelled, _) = Self.harness { _, _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) { try await cancelled.listConversations() }
  }

  // MARK: messages

  @Test("Direct history reads one page of 20, oldest first, without duplicates")
  func directMessages() async throws {
    let (client, transport) = Self.harness { _, _ in
      """
      {"ErrorCode":0,"Complete":1,"MsgList":[\(Self.text("b", from: "bob", seconds: 20)),
        \(Self.text("a", from: "alice", seconds: 10)),\(Self.text("b", from: "bob", seconds: 20))]}
      """
    }
    let messages = try await client.messages(in: ConversationID("c2c_bob"))
    #expect(messages.map(\.id.rawValue) == ["a", "b"])
    #expect(messages.map(\.conversationID.rawValue) == ["c2c_bob", "c2c_bob"])
    let request = try #require(Self.bodies(transport, "openim/admin_getroammsg").first)
    #expect(request["Operator_Account"] as? String == "alice")
    #expect(request["Peer_Account"] as? String == "bob")
    #expect(request["MaxCnt"] as? Int == 20)
  }

  @Test("Group history starts at sequence 0 with recalled messages included")
  func groupMessages() async throws {
    let (client, transport) = Self.harness { _, _ in
      #"{"ErrorCode":0,"IsFinished":1,"MsgList":[\#(Self.text("g", from: "bob", seconds: 5))]}"#
    }
    let messages = try await client.messages(in: ConversationID("group_g1"))
    #expect(messages.count == 1)
    let request = try #require(Self.bodies(transport, "group_open_http_svc/group_msg_get_simple").first)
    #expect(request["GroupId"] as? String == "g1")
    #expect(request["ReqMsgSeq"] as? Int == 0)
    #expect(request["ReqMsgNumber"] as? Int == 20)
    #expect(request["WithRecalledMsg"] as? Int == 1)
  }

  @Test("An empty history succeeds; an unrecognised conversation id is not found")
  func messageEdges() async throws {
    let (client, transport) = Self.harness { _, _ in #"{"ErrorCode":0,"Complete":1}"# }
    #expect(try await client.messages(in: ConversationID("c2c_bob")).isEmpty)
    await #expect(throws: ChatError.conversationNotFound) {
      try await client.messages(in: ConversationID("nonsense"))
    }
    #expect(transport.requests.count == 1)
  }

  // MARK: listUsers

  @Test("Users come from direct peers and group members, exclude me, and use profile nicknames")
  func users() async throws {
    let (client, transport) = Self.harness { operation, _ in
      switch operation {
      case "recentcontact/get_list":
        return """
          {"ErrorCode":0,"CompleteFlag":3,
           "SessionItem":[\(Self.directRow("bob", time: 9)),\(Self.groupRow("g1", time: 8))]}
          """
      case "group_open_http_svc/get_group_member_info":
        return #"{"ErrorCode":0,"MemberNum":3,"MemberList":[\#(Self.members(["alice", "bob", "carol"]))]}"#
      case "profile/portrait_get":
        return """
          {"ErrorCode":0,"UserProfileItem":[
            {"To_Account":"bob","ResultCode":0,"ProfileItem":[{"Tag":"Tag_Profile_IM_Nick","Value":"Bobby"}]},
            {"To_Account":"carol","ResultCode":40001,"ProfileItem":[]}]}
          """
      default: return "{}"
      }
    }
    let users = try await client.listUsers()
    #expect(users.map(\.id.rawValue) == ["bob", "carol"])
    #expect(users.map(\.displayName) == ["Bobby", "carol"])
    #expect(users.map(\.initials) == ["BO", "CA"])
    let request = try #require(Self.bodies(transport, "profile/portrait_get").first)
    #expect(request["To_Account"] as? [String] == ["bob", "carol"])
  }

  @Test("A failed profile lookup falls back to ids instead of failing the user list")
  func usersSurviveProfileFailure() async throws {
    let (client, _) = Self.harness { operation, _ in
      switch operation {
      case "recentcontact/get_list":
        return #"{"ErrorCode":0,"CompleteFlag":3,"SessionItem":[\#(Self.directRow("bob", time: 9))]}"#
      default: return #"{"ErrorCode":91001,"ErrorInfo":"down"}"#
      }
    }
    #expect(try await client.listUsers().map(\.displayName) == ["bob"])
  }

  // MARK: writes

  private func writer(
    nonces: [UInt32] = [7, 8], _ handler: @escaping @Sendable (String, [String: Any]) async throws -> String
  ) -> (LiveChatClient, StubTransport) {
    let (_, transport) = Self.harness(handler)
    let gateway = GatewayClient(
      configuration: GatewayConfiguration(httpBase: URL(string: "https://gw.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let counter = NonceSource(nonces)
    return (
      LiveChatClient(
        gateway: gateway, currentUser: { Self.me }, nonce: { counter.next() },
        now: { Date(timeIntervalSince1970: 1_800_000_000) }), transport
    )
  }

  @Test("A direct send posts sendmsg with a trimmed text element and returns the server key")
  func sendDirect() async throws {
    let (client, transport) = writer { _, _ in
      #"{"ErrorCode":0,"MsgKey":"srv-1","MsgId":"echo","MsgTime":1800000005}"#
    }
    let sent = try await client.send(text: "  hello  ", to: ConversationID("c2c_bob"))
    #expect(sent.id == MessageID("srv-1"))
    #expect(sent.text == "hello")
    #expect(sent.senderID == Self.me)
    #expect(sent.deliveryState == .sent)
    #expect(sent.sentAt == Date(timeIntervalSince1970: 1_800_000_005))
    let request = try #require(Self.bodies(transport, "openim/sendmsg").first)
    #expect(request["From_Account"] as? String == "alice")
    #expect(request["To_Account"] as? String == "bob")
    #expect(request["MsgRandom"] as? Int == 7)
    #expect((request["MsgId"] as? String)?.isEmpty == false)
    let body = try #require(request["MsgBody"] as? [[String: Any]])
    #expect(body.count == 1)
    #expect(body[0]["MsgType"] as? String == "TIMTextElem")
    #expect((body[0]["MsgContent"] as? [String: String]) == ["Text": "hello"])
  }

  @Test("A group send uses send_group_msg and spells the nonce Random")
  func sendGroup() async throws {
    let (client, transport) = writer { _, _ in #"{"ErrorCode":0,"MsgKey":"g-1","MsgTime":1800000006}"# }
    let sent = try await client.send(text: "yo", to: ConversationID("group_g1"))
    #expect(sent.id == MessageID("g-1"))
    let request = try #require(Self.bodies(transport, "group_open_http_svc/send_group_msg").first)
    #expect(request["GroupId"] as? String == "g1")
    #expect(request["Random"] as? Int == 7)
    #expect(request["MsgRandom"] == nil)
    #expect(request["To_Account"] == nil)
  }

  @Test("Blank text, unknown conversations and missing keys never succeed; blank makes no request")
  func sendRejections() async throws {
    let (client, transport) = writer { _, _ in #"{"ErrorCode":0}"# }
    await #expect(throws: ChatError.emptyMessage) {
      try await client.send(text: " \n ", to: ConversationID("c2c_bob"))
    }
    await #expect(throws: ChatError.conversationNotFound) {
      try await client.send(text: "x", to: ConversationID("nonsense"))
    }
    #expect(transport.requests.isEmpty)
    await #expect(throws: GatewayError.invalidResponse) {
      try await client.send(text: "x", to: ConversationID("c2c_bob"))
    }
  }

  @Test("Each send mints a new nonce; nothing is retried by the client")
  func sendUsesFreshNonce() async throws {
    let (client, transport) = writer(nonces: [11, 12]) { _, _ in
      #"{"ErrorCode":0,"MsgKey":"k","MsgTime":1800000000}"#
    }
    _ = try await client.send(text: "a", to: ConversationID("c2c_bob"))
    _ = try await client.send(text: "a", to: ConversationID("c2c_bob"))
    let nonces = Self.bodies(transport, "openim/sendmsg").compactMap { $0["MsgRandom"] as? Int }
    #expect(nonces == [11, 12])
  }

  @Test("A failed send surfaces the error and a signed-out user cannot send")
  func sendFailures() async throws {
    let (client, _) = writer { _, _ in #"{"ErrorCode":93000,"ErrorInfo":"bad"}"# }
    await #expect(throws: GatewayError.envelope(code: 93000, info: "bad")) {
      try await client.send(text: "x", to: ConversationID("c2c_bob"))
    }
    let (signedOut, transport) = Self.harness(user: nil) { _, _ in "{}" }
    await #expect(throws: GatewayError.unauthorized) {
      try await signedOut.send(text: "x", to: ConversationID("c2c_bob"))
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("Creating a direct conversation makes no request and rejects self and blank users")
  func createDirect() async throws {
    let (client, transport) = writer { _, _ in "{}" }
    let conversation = try await client.createDirect(with: UserID("bob"))
    #expect(conversation.id == ConversationID("c2c_bob"))
    #expect(conversation.kind == .direct)
    #expect(conversation.memberIDs == [Self.me, UserID("bob")])
    #expect(conversation.lastMessage == nil)
    await #expect(throws: ChatError.invalidMembers) { try await client.createDirect(with: Self.me) }
    await #expect(throws: ChatError.userNotFound) { try await client.createDirect(with: UserID("  ")) }
    #expect(transport.requests.isEmpty)
  }

  @Test("Creating a group posts create_group with the other members and returns the server id")
  func createGroup() async throws {
    let (client, transport) = writer { _, _ in #"{"ErrorCode":0,"GroupId":"g42"}"# }
    let group = try await client.createGroup(
      name: "  Team  ", members: [UserID("bob"), UserID("alice"), UserID("bob"), UserID("carol")])
    #expect(group.id == ConversationID("group_g42"))
    #expect(group.name == "Team")
    #expect(group.memberIDs == [Self.me, UserID("bob"), UserID("carol")])
    let request = try #require(Self.bodies(transport, "group_open_http_svc/create_group").first)
    #expect(request["Owner_Account"] as? String == "alice")
    #expect(request["Type"] as? String == "Public")
    #expect(request["Name"] as? String == "Team")
    let list = try #require(request["MemberList"] as? [[String: String]])
    #expect(list == [["Member_Account": "bob"], ["Member_Account": "carol"]])
  }

  @Test("Group creation validates the name and member count before any request")
  func createGroupValidation() async throws {
    let (client, transport) = writer { _, _ in #"{"ErrorCode":0,"GroupId":"g"}"# }
    await #expect(throws: ChatError.groupNameRequired) {
      try await client.createGroup(name: "  ", members: [UserID("b"), UserID("c")])
    }
    await #expect(throws: ChatError.invalidMembers) {
      try await client.createGroup(name: "T", members: [UserID("b"), Self.me])
    }
    let tooMany = (0..<51).map { UserID("u\($0)") }
    await #expect(throws: ChatError.invalidMembers) {
      try await client.createGroup(name: "T", members: tooMany)
    }
    #expect(transport.requests.isEmpty)
    let (missing, _) = writer { _, _ in #"{"ErrorCode":0}"# }
    await #expect(throws: GatewayError.invalidResponse) {
      try await missing.createGroup(name: "T", members: [UserID("b"), UserID("c")])
    }
  }

  // MARK: session ending

  @Test("A revoked or unauthorised answer reports the ended session once per failure and still throws")
  func endedSessionIsReported() async throws {
    let reports = ReportCounter()
    let transport = StubTransport(reply: { _ in .gateway(401, json: #"{"ErrorCode":70009}"#) })
    let gateway = GatewayClient(
      configuration: GatewayConfiguration(httpBase: URL(string: "https://gw.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let client = LiveChatClient(
      gateway: gateway, currentUser: { Self.me }, onKicked: { await reports.bump() })
    await #expect(throws: GatewayError.revoked) { try await client.listConversations() }
    #expect(await reports.value == 1)

    let signedOut = LiveChatClient(
      gateway: gateway, currentUser: { nil }, onKicked: { await reports.bump() })
    await #expect(throws: GatewayError.unauthorized) { try await signedOut.messages(in: ConversationID("c2c_bob")) }
    #expect(await reports.value == 2)
  }

  @Test("Service failures do not end the session")
  func serviceFailuresDoNotEndSession() async {
    let reports = ReportCounter()
    let transport = StubTransport(reply: { _ in .gateway(json: #"{"ErrorCode":93000,"ErrorInfo":"x"}"#) })
    let gateway = GatewayClient(
      configuration: GatewayConfiguration(httpBase: URL(string: "https://gw.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let client = LiveChatClient(
      gateway: gateway, currentUser: { Self.me }, onKicked: { await reports.bump() })
    await #expect(throws: GatewayError.envelope(code: 93000, info: "x")) {
      try await client.listConversations()
    }
    #expect(await reports.value == 0)
  }
}

private actor ReportCounter {
  private(set) var value = 0
  func bump() { value += 1 }
}


private nonisolated final class NonceSource: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt32]
  init(_ values: [UInt32]) { self.values = values }
  func next() -> UInt32 { lock.withLock { values.count > 1 ? values.removeFirst() : (values.first ?? 1) } }
}
