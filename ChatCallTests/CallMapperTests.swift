import Foundation
import Testing

@testable import ChatCall

nonisolated struct CallMapperTests {
  private let me = UserID("alice")

  private func wire(
    status: String, group: Bool = false, groupStatus: String? = nil, canJoin: Bool? = nil,
    caller: String = "alice", callee: String = "bob", room: String = "dm_alice_bob",
    participants: [(String, String)]? = nil
  ) -> WireCallInfo {
    let list = participants.map {
      ",\"participants\":[" + $0.map { #"{"user_id":"\#($0.0)","status":"\#($0.1)"}"# }.joined(separator: ",") + "]"
    } ?? ""
    let flags =
      (group ? #","group":true"# : "") + (groupStatus.map { #","group_status":"\#($0)""# } ?? "")
      + (canJoin.map { #","can_join":\#($0)"# } ?? "")
    let json = """
      {"call_id":"call-1","room_id":"\(room)","caller_id":"\(caller)","callee_id":"\(group ? "" : callee)",
       "caller_name":"\(caller.capitalized)","status":"\(status)","created_at":"2026-10-22T09:00:00Z"\(flags)\(list)}
      """
    return try! JSONDecoder().decode(WireCallInfo.self, from: Data(json.utf8))
  }

  private func state(_ wire: WireCallInfo, as user: String = "alice") -> CallState? {
    CallMapper.snapshot(wire, me: UserID(user))?.state
  }

  @Test("Direct calls map from each side's own status")
  func directStates() {
    #expect(state(wire(status: "ringing")) == .ringing)
    #expect(state(wire(status: "ringing"), as: "bob") == .incoming)
    #expect(state(wire(status: "accepted")) == .active)
    #expect(state(wire(status: "rejected")) == .declined)
    #expect(state(wire(status: "missed"), as: "bob") == .missed)
    #expect(state(wire(status: "cancelled")) == .ended)
    #expect(state(wire(status: "cancelled"), as: "bob") == .missed)
    #expect(state(wire(status: "ended")) == .ended)
    #expect(state(wire(status: "weird")) == nil)
  }

  @Test("A group creator rings until someone else has joined, then is active")
  func groupCreator() {
    let alone = wire(
      status: "accepted", group: true, groupStatus: "accepted", room: "grp_demo",
      participants: [("alice", "joined"), ("bob", "invited")])
    let joined = wire(
      status: "accepted", group: true, groupStatus: "accepted", room: "grp_demo",
      participants: [("alice", "joined"), ("bob", "joined")])
    #expect(state(alone) == .ringing)
    #expect(state(joined) == .active)
  }

  @Test("Group invitees: ringing is incoming, accepted is active, rejected and missed are joinable")
  func groupInvitee() throws {
    func call(_ status: String, canJoin: Bool? = nil, groupStatus: String = "accepted") -> WireCallInfo {
      wire(
        status: status, group: true, groupStatus: groupStatus, canJoin: canJoin, caller: "bob",
        room: "grp_demo", participants: [("bob", "joined"), ("alice", status == "accepted" ? "joined" : "invited")])
    }
    #expect(state(call("ringing")) == .incoming)
    #expect(state(call("accepted")) == .active)
    let declined = try #require(CallMapper.snapshot(call("rejected", canJoin: true), me: me))
    #expect(declined.state == .declined && declined.canJoin)
    let missed = try #require(CallMapper.snapshot(call("missed", canJoin: true), me: me))
    #expect(missed.state == .missed && missed.canJoin)
  }

  @Test("A creator who left while others remain is ended for them but can rejoin")
  func creatorLeftCanRejoin() throws {
    let left = wire(
      status: "ended", group: true, groupStatus: "accepted", canJoin: true, room: "grp_demo",
      participants: [("alice", "left"), ("bob", "joined")])
    let snapshot = try #require(CallMapper.snapshot(left, me: me))
    #expect(snapshot.state == .ended)
    #expect(snapshot.canJoin)
    #expect(snapshot.direction == .outgoing)
  }

  @Test("can_join is false when absent, when the group has ended, or while the call is live")
  func canJoinRules() throws {
    func join(_ w: WireCallInfo) throws -> Bool { try #require(CallMapper.snapshot(w, me: me)).canJoin }
    let absent = wire(status: "rejected", group: true, groupStatus: "accepted", caller: "bob", room: "grp_demo")
    #expect(try join(absent) == false)
    let ended = wire(status: "rejected", group: true, groupStatus: "ended", canJoin: true, caller: "bob", room: "grp_demo")
    #expect(try join(ended) == false)
    #expect(try CallMapper.snapshot(ended, me: me)?.state == .declined)
    let live = wire(
      status: "accepted", group: true, groupStatus: "accepted", canJoin: true, caller: "bob",
      room: "grp_demo", participants: [("bob", "joined"), ("alice", "joined")])
    #expect(try join(live) == false)
    let direct = wire(status: "rejected", canJoin: true)
    #expect(try join(direct) == false)
  }

  @Test("Conversation ids: group rooms strip grp_, direct calls use the other party")
  func conversationIDs() throws {
    let group = wire(status: "accepted", group: true, groupStatus: "accepted", room: "grp_g_test")
    #expect(CallMapper.conversationID(of: group, me: me) == ConversationID("group_g_test"))
    let outgoing = wire(status: "ringing", caller: "alice", callee: "u_bob", room: "dm_alice_u_bob")
    #expect(CallMapper.conversationID(of: outgoing, me: me) == ConversationID("c2c_u_bob"))
    let incoming = wire(status: "ringing", caller: "u_bob", callee: "alice", room: "dm_alice_u_bob")
    #expect(CallMapper.conversationID(of: incoming, me: me) == ConversationID("c2c_u_bob"))
    #expect(CallMapper.roomID(for: ConversationID("c2c_u_bob"), me: UserID("alice")) == "dm_alice_u_bob")
    #expect(CallMapper.roomID(for: ConversationID("group_g1"), me: me) == "grp_g1")
    #expect(CallMapper.roomID(for: ConversationID("nonsense"), me: me) == nil)
  }

  @Test("Participants always include me; live calls show only people present, ended calls everyone")
  func participants() throws {
    let live = wire(
      status: "accepted", group: true, groupStatus: "accepted", room: "grp_demo",
      participants: [("alice", "joined"), ("bob", "joined"), ("carol", "invited"), ("dave", "left")])
    let liveSnapshot = try #require(CallMapper.snapshot(live, me: me))
    #expect(liveSnapshot.participants.map(\.id.rawValue) == ["alice", "bob"])
    let ended = wire(
      status: "ended", group: true, groupStatus: "ended", room: "grp_demo",
      participants: [("alice", "left"), ("bob", "left"), ("carol", "missed")])
    #expect(try #require(CallMapper.snapshot(ended, me: me)).participants.count == 3)
    let missingMe = wire(status: "ringing", caller: "bob", callee: "alice")
    #expect(try #require(CallMapper.snapshot(missingMe, me: me)).participants.contains { $0.id == me })
    #expect(liveSnapshot.localUserID == me)
    #expect(liveSnapshot.participants.first { $0.id == UserID("alice") }?.displayName == "Alice")
  }

  @Test("Bad dates and unknown statuses yield nil instead of a crash; fractional seconds parse")
  func badData() throws {
    let json = #"{"call_id":"c","room_id":"r","caller_id":"alice","status":"ringing","created_at":"yesterday"}"#
    let bad = try JSONDecoder().decode(WireCallInfo.self, from: Data(json.utf8))
    #expect(CallMapper.snapshot(bad, me: me) == nil)
    let fractional = try JSONDecoder().decode(
      WireCallInfo.self,
      from: Data(#"{"call_id":"c","room_id":"r","caller_id":"alice","callee_id":"bob","status":"ringing","created_at":"2026-10-22T09:00:00.456Z"}"#.utf8))
    #expect(CallMapper.snapshot(fractional, me: me) != nil)
  }
}
