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

// MARK: requests and responses

nonisolated struct ConversationListRequest: Encodable, Sendable {
  let from: String
  let timeStamp: Double
  let startIndex: Int
  let topTimeStamp: Double
  let topStartIndex: Int
  /// 63 asks for the complete answer, folders included.
  let assistFlags = 63
  /// 0 all, 1 C2C, 2 group.
  let contactType = 0

  private enum CodingKeys: String, CodingKey {
    case from = "From_Account", timeStamp = "TimeStamp", startIndex = "StartIndex"
    case topTimeStamp = "TopTimeStamp", topStartIndex = "TopStartIndex"
    case assistFlags = "AssistFlags", contactType = "ContactType"
  }
}

nonisolated struct ConversationListResponse: Decodable, Sendable {
  let items: [WireConversation]?
  /// 1 normal list exhausted, 2 pinned list exhausted, 3 both.
  let completeFlag: Int?
  let timeStamp: Double?
  let startIndex: Int?
  let topTimeStamp: Double?
  let topStartIndex: Int?

  private enum CodingKeys: String, CodingKey {
    case items = "SessionItem", completeFlag = "CompleteFlag", timeStamp = "TimeStamp"
    case startIndex = "StartIndex", topTimeStamp = "TopTimeStamp", topStartIndex = "TopStartIndex"
  }
}

nonisolated struct GroupMembersRequest: Encodable, Sendable {
  let groupID: String
  let limit: Int
  let offset: Int
  private enum CodingKeys: String, CodingKey {
    case groupID = "GroupId", limit = "Limit", offset = "Offset"
  }
}

nonisolated struct GroupMembersResponse: Decodable, Sendable {
  struct Member: Decodable, Sendable { let account: String?
    private enum CodingKeys: String, CodingKey { case account = "Member_Account" }
  }
  /// Total after filtering, not the size of the page.
  let memberCount: Int?
  let members: [Member]?
  private enum CodingKeys: String, CodingKey { case memberCount = "MemberNum", members = "MemberList" }
}

nonisolated struct DirectHistoryRequest: Encodable, Sendable {
  let operatorAccount: String
  let peerAccount: String
  /// The server ceiling is 20 and it does not clamp: a larger value is an error.
  let maxCount = 20
  let lastMsgKey = ""
  let maxTime = 0
  private enum CodingKeys: String, CodingKey {
    case operatorAccount = "Operator_Account", peerAccount = "Peer_Account"
    case maxCount = "MaxCnt", lastMsgKey = "LastMsgKey", maxTime = "MaxTime"
  }
}

nonisolated struct GroupHistoryRequest: Encodable, Sendable {
  let groupID: String
  let requestSeq = 0
  let requestCount = 20
  let withRecalled = 1
  private enum CodingKeys: String, CodingKey {
    case groupID = "GroupId", requestSeq = "ReqMsgSeq", requestCount = "ReqMsgNumber"
    case withRecalled = "WithRecalledMsg"
  }
}

nonisolated struct HistoryResponse: Decodable, Sendable {
  let messages: [WireMessage]?
  private enum CodingKeys: String, CodingKey { case messages = "MsgList" }
}

nonisolated struct PortraitRequest: Encodable, Sendable {
  let accounts: [String]
  let tags = ["Tag_Profile_IM_Nick"]
  private enum CodingKeys: String, CodingKey { case accounts = "To_Account", tags = "TagList" }
}

nonisolated struct PortraitResponse: Decodable, Sendable {
  struct Item: Decodable, Sendable {
    struct Tag: Decodable, Sendable {
      let name: String?
      let value: String?
      private enum CodingKeys: String, CodingKey { case name = "Tag", value = "Value" }
      init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try? values.decode(String.self, forKey: .name)
        value = try? values.decode(String.self, forKey: .value)
      }
    }
    let account: String?
    let resultCode: Int?
    let tags: [Tag]?
    private enum CodingKeys: String, CodingKey {
      case account = "To_Account", resultCode = "ResultCode", tags = "ProfileItem"
    }
  }
  let items: [Item]?
  private enum CodingKeys: String, CodingKey { case items = "UserProfileItem" }
}
