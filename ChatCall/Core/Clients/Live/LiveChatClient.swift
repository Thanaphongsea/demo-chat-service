import Foundation
import OSLog

nonisolated let chatLog = Logger(subsystem: "com.example.ChatCall", category: "chat")

/// Chat over the real gateway. Business rules mirror the reference web app (`webapp/lib/*`).
actor LiveChatClient: ChatClient {
  private static let maxListPages = 20
  private static let memberPage = 100
  private static let maxRosterPages = 20
  private static let portraitBatch = 100

  /// The contract accepts at most 50 listed members when a group is created.
  private static let maxNewGroupMembers = 50

  private let gateway: GatewayClient
  private let currentUser: @Sendable () async -> UserID?
  private let nonce: @Sendable () -> UInt32
  private let now: @Sendable () -> Date
  private let realtime: (any RealtimeConnection)?
  private let deviceID: String?
  private let onKicked: @Sendable () async -> Void
  /// Own messages still `.sent`, per conversation, so a read receipt can mark them delivered.
  private var unreadOwn: [ConversationID: [(id: MessageID, sentAt: Date)]] = [:]
  private var rosterCache: [String: [UserID]] = [:]

  /// `currentUser` is asked on every operation, so an account switch or sign-out takes effect at once.
  init(
    gateway: GatewayClient, currentUser: @escaping @Sendable () async -> UserID?,
    nonce: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max) },
    now: @escaping @Sendable () -> Date = { Date() },
    realtime: (any RealtimeConnection)? = nil, deviceID: String? = nil,
    onKicked: @escaping @Sendable () async -> Void = {}
  ) {
    self.gateway = gateway
    self.currentUser = currentUser
    self.nonce = nonce
    self.now = now
    self.realtime = realtime
    self.deviceID = deviceID
    self.onKicked = onKicked
  }

  // MARK: reads

  func listConversations() async throws -> [Conversation] {
    let me = try await requireUser()
    let rows = try await conversationRows(me: me)
    let rosters = try await rosters(for: rows)
    rosterCache.merge(rosters) { _, fresh in fresh }
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
    let loaded = wire.compactMap { ChatMapper.message($0, in: conversationID, me: me) }
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.sentAt != $1.sentAt ? $0.sentAt < $1.sentAt : $0.id.rawValue < $1.id.rawValue }
    for message in loaded { rememberUnread(message) }
    return loaded
  }

  // MARK: writes and events

  /// Every call mints a fresh nonce and is never retried here: if the answer is lost after the server
  /// accepted the message, sending again duplicates it (the contract has no client request id yet).
  func send(text: String, to conversationID: ConversationID) async throws -> Message {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ChatError.emptyMessage }
    guard let target = Self.target(of: conversationID) else { throw ChatError.conversationNotFound }
    let me = try await requireUser()
    let random = Int(nonce())
    let clientID = UUID().uuidString.lowercased()
    let body = [OutgoingTextElement(text: trimmed)]
    let reply: SendResponse
    switch target {
    case .direct(let peer):
      reply = try await gateway.post(
        "openim/sendmsg",
        body: SendDirectRequest(
          from: me.rawValue, to: peer, random: random, id: clientID, body: body))
    case .group(let group):
      reply = try await gateway.post(
        "group_open_http_svc/send_group_msg",
        body: SendGroupRequest(
          from: me.rawValue, groupID: group, random: random, id: clientID, body: body))
    }
    guard let key = [reply.key, reply.id].lazy.compactMap({ $0 }).first(where: { !$0.isEmpty })
    else { throw GatewayError.invalidResponse }
    let message = Message(
      id: MessageID(key), conversationID: conversationID, senderID: me, text: trimmed,
      sentAt: reply.time.map { Date(timeIntervalSince1970: $0) } ?? now(), deliveryState: .sent)
    rememberUnread(message)
    return message
  }

  /// A direct conversation exists once the first message is sent, so this makes no request.
  func createDirect(with userID: UserID) async throws -> Conversation {
    let me = try await requireUser()
    let peer = userID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !peer.isEmpty else { throw ChatError.userNotFound }
    guard peer != me.rawValue else { throw ChatError.invalidMembers }
    return try Conversation(
      id: ConversationID("c2c_\(peer)"), kind: .direct, name: peer,
      memberIDs: [me, UserID(peer)], updatedAt: now())
  }

  func createGroup(name: String, members: [UserID]) async throws -> Conversation {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ChatError.groupNameRequired }
    let me = try await requireUser()
    var seen: Set<UserID> = [me]
    let others = members.filter { seen.insert($0).inserted }
    guard others.count >= 2, others.count <= Self.maxNewGroupMembers else {
      throw ChatError.invalidMembers
    }
    let reply: CreateGroupResponse = try await gateway.post(
      "group_open_http_svc/create_group",
      body: CreateGroupRequest(
        owner: me.rawValue, name: title,
        members: others.map { CreateGroupRequest.Member(account: $0.rawValue) }))
    guard let group = reply.groupID, !group.isEmpty else { throw GatewayError.invalidResponse }
    return try Conversation(
      id: ConversationID("group_\(group)"), kind: .group, name: title, memberIDs: [me] + others,
      updatedAt: now())
  }

  func events() async -> AsyncStream<ChatEvent> {
    guard let realtime else { return AsyncStream { $0.finish() } }
    let upstream = realtime.events()
    await realtime.start()
    let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
    let task = Task {
      for await event in upstream {
        for translated in await self.translate(event) { continuation.yield(translated) }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// Stops the shared socket, e.g. on sign-out.
  func stopRealtime() async {
    await realtime?.stop()
    unreadOwn = [:]
    rosterCache = [:]
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

  // MARK: realtime translation

  private func translate(_ event: RealtimeEvent) async -> [ChatEvent] {
    guard let me = await currentUser() else { return [] }
    switch event {
    case .newMessage(let wire):
      guard let id = ChatMapper.conversationID(of: wire, me: me),
        let message = ChatMapper.message(wire, in: id, me: me)
      else { return [] }
      rememberUnread(message)
      return [.messageInserted(message)]
    case .conversationChanged(let wire):
      guard let conversation = await conversation(from: wire, me: me) else { return [] }
      return [.conversationUpdated(conversation)]
    case .readReceipt(let id, let readAt):
      let conversationID = ConversationID(id)
      let (read, waiting) = (unreadOwn[conversationID] ?? []).reduce(into: ([MessageID](), [(id: MessageID, sentAt: Date)]())) {
        $1.sentAt <= readAt ? $0.0.append($1.id) : $0.1.append($1)
      }
      unreadOwn[conversationID] = waiting
      return read.map {
        .deliveryChanged(messageID: $0, conversationID: conversationID, state: .delivered)
      }
    case .kicked(let device):
      // A kick names a device only when it targets one; no device means the whole account.
      guard device == nil || deviceID == nil || device == deviceID else { return [] }
      await onKicked()
      return []
    case .reconnected:
      // Events published while the socket was down are gone; re-read the list as updates.
      guard let conversations = try? await listConversations() else { return [] }
      return conversations.map { .conversationUpdated($0) }
    case .unknown:
      return []
    }
  }

  /// Group rows need a complete roster: use the cached one, fetch it once, else skip the event.
  private func conversation(from wire: WireConversation, me: UserID) async -> Conversation? {
    guard let group = wire.groupID, !group.isEmpty else {
      return ChatMapper.conversation(wire, me: me, members: nil)
    }
    if rosterCache[group] == nil {
      guard let fetched = try? await roster(of: group) else {
        chatLog.notice("conversation event dropped: roster unavailable")
        return nil
      }
      rosterCache[group] = fetched
    }
    return ChatMapper.conversation(wire, me: me, members: rosterCache[group])
  }

  private func rememberUnread(_ message: Message) {
    guard message.deliveryState == .sent else { return }
    var list = unreadOwn[message.conversationID] ?? []
    guard !list.contains(where: { $0.id == message.id }) else { return }
    list.append((message.id, message.sentAt))
    unreadOwn[message.conversationID] = Array(list.suffix(200))
  }
}
