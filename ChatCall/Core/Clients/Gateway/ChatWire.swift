import Foundation

/// One element of a message body. Only text is understood; every other element type is opaque.
nonisolated struct WireBodyElement: Decodable, Sendable, Equatable {
  let type: String
  let text: String?

  private enum CodingKeys: String, CodingKey { case type = "MsgType", content = "MsgContent" }
  private enum ContentKeys: String, CodingKey { case text = "Text" }

  init(type: String, text: String?) {
    self.type = type
    self.text = text
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    type = (try? values.decode(String.self, forKey: .type)) ?? ""
    let content = try? values.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
    text = try? content?.decodeIfPresent(String.self, forKey: .text)
  }
}

/// A message as the contract renders it: on delivery, in a history page and as a `lastMessage` snapshot.
nonisolated struct WireMessage: Decodable, Sendable, Equatable {
  let key: String?
  let id: String?
  let from: String?
  let to: String?
  let groupID: String?
  let seq: Int?
  let random: Int?
  /// Unix seconds, never milliseconds.
  let timestamp: Double?
  let body: [WireBodyElement]?
  /// Group: 0 normal, 1 unavailable, 2 recalled.
  let placeFlag: Int?
  /// C2C: 0 normal, 8 recalled.
  let flagBits: Int?
  /// C2C, own messages only: 1 once the peer has read it.
  let peerRead: Int?

  private enum CodingKeys: String, CodingKey {
    case key = "MsgKey", id = "MsgId", from = "From_Account", to = "To_Account"
    case groupID = "GroupId", seq = "MsgSeq", random = "MsgRandom", timestamp = "MsgTimeStamp"
    case body = "MsgBody", placeFlag = "IsPlaceMsg", flagBits = "MsgFlagBits"
    case peerRead = "IsPeerRead"
  }
}

/// One row of the conversation list.
nonisolated struct WireConversation: Decodable, Sendable, Equatable {
  /// 1 = C2C, 2 = group.
  let type: Int?
  let peer: String?
  let groupID: String?
  /// Viewer-relative: `c2c_<peer>` / `group_<gid>`.
  let conversationID: String?
  let unreadCount: Int?
  let lastMessage: WireMessage?
  let showName: String?
  /// Unix seconds.
  let time: Double?

  private enum CodingKeys: String, CodingKey {
    case type = "Type", peer = "To_Account", groupID = "GroupId", conversationID
    case unreadCount, lastMessage, showName, time = "MsgTime"
  }
}
