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
}
