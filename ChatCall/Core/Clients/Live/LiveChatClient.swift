import Foundation
import OSLog

nonisolated let chatLog = Logger(subsystem: "com.example.ChatCall", category: "chat")

/// Chat over the real gateway. Business rules mirror the reference web app (`webapp/lib/*`).
actor LiveChatClient: ChatClient {
  private static let maxListPages = 20
  private static let memberPage = 100
  private static let maxRosterPages = 20
  private static let portraitBatch = 100

  private let gateway: GatewayClient
  private let currentUser: @Sendable () async -> UserID?

  /// `currentUser` is asked on every operation, so an account switch or sign-out takes effect at once.
  init(gateway: GatewayClient, currentUser: @escaping @Sendable () async -> UserID?) {
    self.gateway = gateway
    self.currentUser = currentUser
  }

  // MARK: reads

  func listConversations() async throws -> [Conversation] {
    let me = try await requireUser()
    let rows = try await conversationRows(me: me)
    let rosters = try await rosters(for: rows)
    var seen: Set<ConversationID> = []
    let conversations = rows.compactMap { row -> Conversation? in
      guard let id = ChatMapper.conversationID(row), seen.insert(id).inserted else { return nil }
      return ChatMapper.conversation(row, me: me, members: row.groupID.flatMap { rosters[$0] })
    }
    return conversations.sorted {
      $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.rawValue < $1.id.rawValue
    }
  }

  func listUsers() async throws -> [User] {
    let me = try await requireUser()
    var ids: [UserID] = []
    var seen: Set<UserID> = [me]
    for conversation in try await listConversations() {
      for id in conversation.memberIDs where seen.insert(id).inserted { ids.append(id) }
    }
    let names = try await displayNames(for: ids)
    return ids.map { id in
      let name = names[id] ?? id.rawValue
      return User(id: id, displayName: name, initials: String(name.prefix(2)).uppercased())
    }
  }

  func messages(in conversationID: ConversationID) async throws -> [Message] {
    let me = try await requireUser()
    let wire: [WireMessage]
    switch Self.target(of: conversationID) {
    case .direct(let peer):
      let reply: HistoryResponse = try await gateway.post(
        "openim/admin_getroammsg",
        body: DirectHistoryRequest(operatorAccount: me.rawValue, peerAccount: peer))
      wire = reply.messages ?? []
    case .group(let group):
      let reply: HistoryResponse = try await gateway.post(
        "group_open_http_svc/group_msg_get_simple", body: GroupHistoryRequest(groupID: group))
      wire = reply.messages ?? []
    case nil:
      throw ChatError.conversationNotFound
    }
    var seen: Set<MessageID> = []
    return wire.compactMap { ChatMapper.message($0, in: conversationID, me: me) }
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.sentAt != $1.sentAt ? $0.sentAt < $1.sentAt : $0.id.rawValue < $1.id.rawValue }
  }

  // MARK: writes (Task 5) and events (Task 6)

  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    throw ChatError.conversationNotFound
  }

  func createDirect(with userID: UserID) async throws -> Conversation {
    throw ChatError.userNotFound
  }

  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    throw ChatError.invalidMembers
  }

  func events() async -> AsyncStream<ChatEvent> {
    AsyncStream { $0.finish() }
  }

  // MARK: helpers

  enum Target: Equatable {
    case direct(peer: String)
    case group(id: String)
  }

  static func target(of id: ConversationID) -> Target? {
    let raw = id.rawValue
    if raw.hasPrefix("c2c_"), raw.count > 4 { return .direct(peer: String(raw.dropFirst(4))) }
    if raw.hasPrefix("group_"), raw.count > 6 { return .group(id: String(raw.dropFirst(6))) }
    return nil
  }

  private func requireUser() async throws -> UserID {
    guard let user = await currentUser() else { throw GatewayError.unauthorized }
    return user
  }

  /// Reads the pinned and normal lists, each on its own cursor, until the server says both are done.
  private func conversationRows(me: UserID) async throws -> [WireConversation] {
    var rows: [WireConversation] = []
    var request = ConversationListRequest(
      from: me.rawValue, timeStamp: 0, startIndex: 0, topTimeStamp: 0, topStartIndex: 0)
    for _ in 0..<Self.maxListPages {
      let page: ConversationListResponse = try await gateway.post(
        "recentcontact/get_list", body: request)
      let items = page.items ?? []
      rows += items
      if page.completeFlag == 3 || items.isEmpty { return rows }
      request = ConversationListRequest(
        from: me.rawValue, timeStamp: page.timeStamp ?? request.timeStamp,
        startIndex: page.startIndex ?? request.startIndex,
        topTimeStamp: page.topTimeStamp ?? request.topTimeStamp,
        topStartIndex: page.topStartIndex ?? request.topStartIndex)
    }
    chatLog.notice("conversation list stopped at the page cap")
    return rows
  }

  /// A complete roster per group. A short or failed page throws: a truncated roster is never returned.
  private func rosters(for rows: [WireConversation]) async throws -> [String: [UserID]] {
    let groups = Set(rows.compactMap { row in (row.groupID ?? "").isEmpty ? nil : row.groupID })
    return try await withThrowingTaskGroup(of: (String, [UserID]).self) { taskGroup in
      for group in groups { taskGroup.addTask { (group, try await self.roster(of: group)) } }
      var result: [String: [UserID]] = [:]
      for try await (group, members) in taskGroup { result[group] = members }
      return result
    }
  }

  private func roster(of group: String) async throws -> [UserID] {
    var members: [UserID] = []
    var total = 0
    for _ in 0..<Self.maxRosterPages {
      let page: GroupMembersResponse = try await gateway.post(
        "group_open_http_svc/get_group_member_info",
        body: GroupMembersRequest(groupID: group, limit: Self.memberPage, offset: members.count))
      let got = (page.members ?? []).compactMap(\.account).map { UserID($0) }
      total = page.memberCount ?? 0
      members += got
      if got.count < Self.memberPage || members.count >= total { break }
    }
    guard members.count >= total else { throw GatewayError.invalidResponse }
    return members
  }

  /// Names are cosmetic: a failed lookup falls back to ids, but auth failures still surface.
  private func displayNames(for ids: [UserID]) async throws -> [UserID: String] {
    var names: [UserID: String] = [:]
    for start in stride(from: 0, to: ids.count, by: Self.portraitBatch) {
      let batch = ids[start..<min(start + Self.portraitBatch, ids.count)].map(\.rawValue)
      do {
        let reply: PortraitResponse = try await gateway.post(
          "profile/portrait_get", body: PortraitRequest(accounts: batch))
        for item in reply.items ?? [] where (item.resultCode ?? 0) == 0 {
          let nick = item.tags?.first { $0.name == "Tag_Profile_IM_Nick" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if let account = item.account, let nick, !nick.isEmpty { names[UserID(account)] = nick }
        }
      } catch GatewayError.envelope, GatewayError.transport, GatewayError.server,
        GatewayError.rateLimited, GatewayError.invalidResponse
      {
        chatLog.notice("portrait lookup failed; showing ids")
      }
    }
    return names
  }
}
