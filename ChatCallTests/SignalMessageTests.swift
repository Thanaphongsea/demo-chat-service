import Foundation
import Testing

@testable import ChatCall

nonisolated struct SignalMessageTests {
  private func json(_ message: SignalMessage) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: message.encoded()) as? [String: Any])
  }

  @Test("Offers and answers nest the description under sdp and carry no to field")
  func offerAndAnswerShape() throws {
    let offer = try json(.offer(SessionDescription(type: "offer", sdp: "v=0\r\n")))
    #expect(offer["type"] as? String == "offer")
    let sdp = try #require(offer["sdp"] as? [String: String])
    #expect(sdp == ["type": "offer", "sdp": "v=0\r\n"])
    #expect(offer["to"] == nil)
    let answer = try json(.answer(SessionDescription(type: "answer", sdp: "x")))
    #expect(answer["type"] as? String == "answer")
  }

  @Test("ICE candidates keep sdpMid and sdpMLineIndex; absent values are explicit nulls")
  func iceShape() throws {
    let full = try json(.ice(IceCandidate(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0)))
    let body = try #require(full["candidate"] as? [String: Any])
    #expect(body["candidate"] as? String == "candidate:1")
    #expect(body["sdpMid"] as? String == "0")
    #expect(body["sdpMLineIndex"] as? Int == 0)
    let bare = try json(.ice(IceCandidate(candidate: "c", sdpMid: nil, sdpMLineIndex: nil)))
    let nulls = try #require(bare["candidate"] as? [String: Any])
    #expect(nulls["sdpMid"] is NSNull && nulls["sdpMLineIndex"] is NSNull)
  }

  @Test("Video subscriptions: an array of user ids, an empty array for none, null for everyone")
  func subscriptions() throws {
    #expect(try json(.videoSubscriptions(["bob", "carol"]))["video_peers"] as? [String] == ["bob", "carol"])
    #expect(try json(.videoSubscriptions([]))["video_peers"] as? [String] == [])
    #expect(try json(.videoSubscriptions(nil))["video_peers"] is NSNull)
    #expect(try json(.videoSubscriptions(["bob"]))["type"] as? String == "video_subscriptions")
  }

  @Test("Server-only messages cannot be sent")
  func notSendable() {
    for message in [SignalMessage.roomPeers([]), .peerJoined("a"), .peerLeft("a"), .error("x"), .unknown("y")] {
      #expect(throws: SignalError.notSendable) { try message.encoded() }
    }
  }

  @Test("Incoming offers, answers, ICE and roster events decode")
  func decodes() {
    let offer = Data(#"{"type":"offer","sdp":{"type":"offer","sdp":"v=0"}}"#.utf8)
    #expect(SignalMessage.decode(offer) == .offer(SessionDescription(type: "offer", sdp: "v=0")))
    let answer = Data(#"{"type":"answer","sdp":{"type":"answer","sdp":"v=1"}}"#.utf8)
    #expect(SignalMessage.decode(answer) == .answer(SessionDescription(type: "answer", sdp: "v=1")))
    let ice = Data(#"{"type":"ice","candidate":{"candidate":"candidate:9","sdpMid":"1","sdpMLineIndex":1}}"#.utf8)
    #expect(SignalMessage.decode(ice) == .ice(IceCandidate(candidate: "candidate:9", sdpMid: "1", sdpMLineIndex: 1)))
    #expect(SignalMessage.decode(Data(#"{"type":"room_peers","from":"server","peers":["bob","carol"]}"#.utf8)) == .roomPeers(["bob", "carol"]))
    #expect(SignalMessage.decode(Data(#"{"type":"peer_joined","from":"dave"}"#.utf8)) == .peerJoined("dave"))
    #expect(SignalMessage.decode(Data(#"{"type":"peer_left","from":"carol"}"#.utf8)) == .peerLeft("carol"))
    #expect(SignalMessage.decode(Data(#"{"type":"error","error":"nope"}"#.utf8)) == .error("nope"))
  }

  @Test("Unknown types and malformed bodies degrade to .unknown; non-messages are nil")
  func degrades() {
    #expect(SignalMessage.decode(Data(#"{"type":"mystery"}"#.utf8)) == .unknown("mystery"))
    #expect(SignalMessage.decode(Data(#"{"type":"offer"}"#.utf8)) == .unknown("offer"))
    #expect(SignalMessage.decode(Data(#"{"type":"ice","candidate":{}}"#.utf8)) == .unknown("ice"))
    #expect(SignalMessage.decode(Data(#"{"type":"peer_joined"}"#.utf8)) == .unknown("peer_joined"))
    #expect(SignalMessage.decode(Data("[]".utf8)) == nil)
    #expect(SignalMessage.decode(Data("not json".utf8)) == nil)
    #expect(SignalMessage.decode(Data("{}".utf8)) == nil)
  }
}
