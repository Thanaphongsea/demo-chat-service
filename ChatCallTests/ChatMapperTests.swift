import Foundation
import Testing

@testable import ChatCall

nonisolated struct ChatMapperTests {
  private let me = UserID("alice")
  private let conversation = ConversationID("c2c_bob")

  private func message(_ json: String) throws -> WireMessage {
    try JSONDecoder().decode(WireMessage.self, from: Data(json.utf8))
  }

  private func row(_ json: String) throws -> WireConversation {
    try JSONDecoder().decode(WireConversation.self, from: Data(json.utf8))
  }

  @Test("DM room ids are byte-sorted with a single underscore")
  func roomID() {
    #expect(ChatMapper.roomID(me: UserID("u_bob"), peer: UserID("alice")) == "dm_alice_u_bob")
    #expect(
      ChatMapper.roomID(me: UserID("alice"), peer: UserID("u_bob"))
        == ChatMapper.roomID(me: UserID("u_bob"), peer: UserID("alice")))
    #expect(ChatMapper.roomID(me: UserID("Zed"), peer: UserID("amy")) == "dm_Zed_amy")
  }

  @Test("Text bodies map with a seconds timestamp and the server key as id")
  func textMessage() throws {
    let wire = try message(
      """
      {"MsgKey":"k1","From_Account":"bob","To_Account":"alice","MsgTimeStamp":1761124800,
       "MsgBody":[{"MsgType":"TIMTextElem","MsgContent":{"Text":"hello "}},
                  {"MsgType":"TIMTextElem","MsgContent":{"Text":"there"}}]}
      """)
    let mapped = try #require(ChatMapper.message(wire, in: conversation, me: me))
    #expect(mapped.id == MessageID("k1"))
    #expect(mapped.senderID == UserID("bob"))
    #expect(mapped.text == "hello there")
    #expect(mapped.sentAt == Date(timeIntervalSince1970: 1_761_124_800))
    #expect(mapped.conversationID == conversation)
  }

  @Test("Non-text, empty and missing bodies become a placeholder, never nil or a crash")
  func unsupportedBodies() throws {
    for body in [
      #"[{"MsgType":"TIMImageElem","MsgContent":{"UUID":"x","ImageInfoArray":[]}}]"#,
      #"[{"MsgType":"TIMCustomElem","MsgContent":{"Data":"{}","Desc":7}}]"#,
      "[]",
      #"[{"MsgType":"TIMTextElem","MsgContent":{"Text":5}}]"#
    ] {
      let wire = try message(#"{"MsgKey":"k","From_Account":"bob","MsgBody":\#(body)}"#)
      #expect(ChatMapper.message(wire, in: conversation, me: me)?.text == "[Unsupported message]")
    }
    let noBody = try message(#"{"MsgKey":"k","From_Account":"bob"}"#)
    #expect(ChatMapper.message(noBody, in: conversation, me: me)?.text == "[Unsupported message]")
  }

  @Test("A message with no identity at all is skipped; MsgId and MsgRandom are fallbacks")
  func identityFallbacks() throws {
    #expect(ChatMapper.message(try message("{}"), in: conversation, me: me) == nil)
    #expect(
      ChatMapper.message(try message(#"{"MsgId":"m9"}"#), in: conversation, me: me)?.id
        == MessageID("m9"))
    #expect(
      ChatMapper.message(try message(#"{"MsgRandom":42}"#), in: conversation, me: me)?.id
        == MessageID("random-42"))
  }

  @Test("Recalled messages are tombstones for groups (IsPlaceMsg 2) and C2C (MsgFlagBits 8)")
  func recalled() throws {
    for flag in [#""IsPlaceMsg":2"#, #""MsgFlagBits":8"#] {
      let wire = try message(
        #"{"MsgKey":"k","From_Account":"bob",\#(flag),"MsgBody":[{"MsgType":"TIMTextElem","MsgContent":{"Text":"secret"}}]}"#
      )
      #expect(ChatMapper.message(wire, in: conversation, me: me)?.text == "Message was recalled")
    }
  }

  @Test("Delivery: incoming is delivered, own is sent until the peer has read it")
  func deliveryState() throws {
    let incoming = try message(#"{"MsgKey":"a","From_Account":"bob"}"#)
    let ownUnread = try message(#"{"MsgKey":"b","From_Account":"alice"}"#)
    let ownRead = try message(#"{"MsgKey":"c","From_Account":"alice","IsPeerRead":1}"#)
    #expect(ChatMapper.message(incoming, in: conversation, me: me)?.deliveryState == .delivered)
    #expect(ChatMapper.message(ownUnread, in: conversation, me: me)?.deliveryState == .sent)
    #expect(ChatMapper.message(ownRead, in: conversation, me: me)?.deliveryState == .delivered)
  }

  @Test("A direct row has exactly me and the peer, with the wire name and last message")
  func directConversation() throws {
    let wire = try row(
      """
      {"Type":1,"To_Account":"bob","conversationID":"c2c_bob","unreadCount":3,"showName":" Bob ",
       "MsgTime":1761124900,
       "lastMessage":{"MsgKey":"k","From_Account":"bob","MsgTimeStamp":1761124900,
         "MsgBody":[{"MsgType":"TIMTextElem","MsgContent":{"Text":"hi"}}]}}
      """)
    let mapped = try #require(ChatMapper.conversation(wire, me: me, members: nil))
    #expect(mapped.id == ConversationID("c2c_bob"))
    #expect(mapped.kind == .direct)
    #expect(mapped.name == "Bob")
    #expect(mapped.memberIDs == [me, UserID("bob")])
    #expect(mapped.unreadCount == 3)
    #expect(mapped.lastMessage?.text == "hi")
    #expect(mapped.updatedAt == Date(timeIntervalSince1970: 1_761_124_900))
  }

  @Test("The id is derived when the wire omits conversationID")
  func derivedIDs() throws {
    #expect(
      ChatMapper.conversationID(try row(#"{"Type":1,"To_Account":"bob"}"#))
        == ConversationID("c2c_bob"))
    #expect(
      ChatMapper.conversationID(try row(#"{"Type":2,"GroupId":"g1"}"#))
        == ConversationID("group_g1"))
    #expect(ChatMapper.conversationID(try row("{}")) == nil)
  }

  @Test("A group with only two members is kept, not dropped")
  func smallGroup() throws {
    let wire = try row(#"{"Type":2,"GroupId":"g1","showName":"Duo","conversationID":"group_g1"}"#)
    let mapped = try #require(
      ChatMapper.conversation(wire, me: me, members: [me, UserID("bob")]))
    #expect(mapped.kind == .group)
    #expect(mapped.memberIDs == [me, UserID("bob")])
    let alone = try #require(ChatMapper.conversation(wire, me: me, members: nil))
    #expect(alone.memberIDs == [me])
  }

  @Test("Group rosters are deduplicated and always include me once")
  func groupRoster() throws {
    let wire = try row(#"{"Type":2,"GroupId":"g1","showName":"Team"}"#)
    let mapped = try #require(
      ChatMapper.conversation(
        wire, me: me, members: [UserID("bob"), UserID("bob"), UserID("carol")]))
    #expect(mapped.memberIDs == [me, UserID("bob"), UserID("carol")])
  }

  @Test("A blank name falls back to the peer or group id; missing last message is nil")
  func fallbacks() throws {
    let direct = try row(#"{"Type":1,"To_Account":"bob","showName":"  "}"#)
    let group = try row(#"{"Type":2,"GroupId":"g1"}"#)
    #expect(ChatMapper.conversation(direct, me: me, members: nil)?.name == "bob")
    #expect(ChatMapper.conversation(direct, me: me, members: nil)?.lastMessage == nil)
    #expect(ChatMapper.conversation(group, me: me, members: nil)?.name == "g1")
  }

  @Test("Unusable rows are skipped rather than failing the list")
  func unusableRows() throws {
    #expect(ChatMapper.conversation(try row(#"{"Type":1}"#), me: me, members: nil) == nil)
    #expect(
      ChatMapper.conversation(try row(#"{"Type":1,"To_Account":"alice"}"#), me: me, members: nil)
        == nil)
  }
}
