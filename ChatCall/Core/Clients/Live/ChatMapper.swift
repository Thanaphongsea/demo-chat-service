import Foundation

/// Pure wire-to-domain mapping. It never throws and never crashes on content it does not understand.
nonisolated enum ChatMapper {
  static let unsupportedText = "[Unsupported message]"
  static let recalledText = "Message was recalled"

  /// `dm_<min>_<max>`: both users derive the same id, byte-sorted, single underscore.
  static func roomID(me: UserID, peer: UserID) -> String {
    let pair = [me.rawValue, peer.rawValue].sorted {
      Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }
    return "dm_\(pair[0])_\(pair[1])"
  }

  static func conversationID(_ wire: WireConversation) -> ConversationID? {
    if let id = wire.conversationID, !id.isEmpty { return ConversationID(id) }
    if let group = wire.groupID, !group.isEmpty { return ConversationID("group_\(group)") }
    if let peer = wire.peer, !peer.isEmpty { return ConversationID("c2c_\(peer)") }
    return nil
  }

  /// The conversation a realtime message belongs to: the payload's own id, else derived from its addressing.
  static func conversationID(of wire: WireMessage, me: UserID) -> ConversationID? {
    if let id = wire.conversationID, !id.isEmpty { return ConversationID(id) }
    if let group = wire.groupID, !group.isEmpty { return ConversationID("group_\(group)") }
    let peer = wire.from == me.rawValue ? wire.to : wire.from
    guard let peer, !peer.isEmpty else { return nil }
    return ConversationID("c2c_\(peer)")
  }

  static func message(_ wire: WireMessage, in conversation: ConversationID, me: UserID) -> Message? {
    guard let id = identity(of: wire) else { return nil }
    let sender = UserID(wire.from ?? "")
    let state: DeliveryState = sender != me || wire.peerRead == 1 ? .delivered : .sent
    return Message(
      id: MessageID(id), conversationID: conversation, senderID: sender, text: text(of: wire),
      sentAt: Date(timeIntervalSince1970: wire.timestamp ?? 0), deliveryState: state)
  }

  /// `members` is the complete roster for a group; without it the group lists only the viewer.
  static func conversation(_ wire: WireConversation, me: UserID, members: [UserID]?)
    -> Conversation?
  {
    guard let id = conversationID(wire) else { return nil }
    let isGroup = wire.type == 2 || !(wire.groupID ?? "").isEmpty
    let trimmedName = (wire.showName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: ConversationKind = isGroup ? .group : .direct
    let roster: [UserID]
    let name: String
    if isGroup {
      var seen: Set<UserID> = []
      roster = ([me] + (members ?? [])).filter { seen.insert($0).inserted }
      name = trimmedName.isEmpty ? (wire.groupID ?? id.rawValue) : trimmedName
    } else {
      guard let peer = wire.peer, !peer.isEmpty else { return nil }
      roster = [me, UserID(peer)]
      name = trimmedName.isEmpty ? peer : trimmedName
    }
    let last = wire.lastMessage.flatMap { message($0, in: id, me: me) }
    let updated = wire.time ?? wire.lastMessage?.timestamp ?? 0
    return try? Conversation(
      id: id, kind: kind, name: name, memberIDs: roster, unreadCount: max(0, wire.unreadCount ?? 0),
      lastMessage: last, updatedAt: Date(timeIntervalSince1970: updated))
  }

  /// MsgKey identifies a delivered message; MsgId/MsgRandom only exist on client-originated ones.
  private static func identity(of wire: WireMessage) -> String? {
    if let key = wire.key, !key.isEmpty { return key }
    if let id = wire.id, !id.isEmpty { return id }
    if let random = wire.random { return "random-\(random)" }
    return nil
  }

  private static func isRecalled(_ wire: WireMessage) -> Bool {
    wire.placeFlag == 2 || wire.flagBits == 8
  }

  private static func text(of wire: WireMessage) -> String {
    if isRecalled(wire) { return recalledText }
    let parts = (wire.body ?? []).filter { $0.type == "TIMTextElem" }.compactMap(\.text)
    return parts.isEmpty ? unsupportedText : parts.joined()
  }
}
