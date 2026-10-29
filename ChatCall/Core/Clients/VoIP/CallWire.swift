import Foundation

nonisolated struct WireParticipant: Decodable, Sendable, Equatable {
  let userID: String
  /// invited, joined, rejected, missed, left.
  let status: String
  private enum CodingKeys: String, CodingKey { case userID = "user_id", status }
}

/// A call as the VoIP API renders it. `status` is the requester's own view; `groupStatus` is the shared one.
nonisolated struct WireCallInfo: Decodable, Sendable, Equatable {
  let callID: String
  let roomID: String
  let callerID: String
  let calleeID: String?
  let callerName: String?
  /// ringing, accepted, rejected, cancelled, missed, ended.
  let status: String
  let group: Bool?
  /// accepted or ended; absent on 1:1 calls.
  let groupStatus: String?
  /// Server-computed capability; absent means false.
  let canJoin: Bool?
  let participants: [WireParticipant]?
  /// RFC 3339, possibly with fractional seconds.
  let createdAt: String

  private enum CodingKeys: String, CodingKey {
    case callID = "call_id", roomID = "room_id", callerID = "caller_id", calleeID = "callee_id"
    case callerName = "caller_name", status, group, groupStatus = "group_status"
    case canJoin = "can_join", participants, createdAt = "created_at"
  }
}

nonisolated struct WireInbox: Decodable, Sendable, Equatable {
  let calls: [WireCallInfo]
  let joinableCalls: [WireCallInfo]

  private enum CodingKeys: String, CodingKey { case calls, joinableCalls = "joinable_calls" }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    calls = try values.decodeIfPresent([WireCallInfo].self, forKey: .calls) ?? []
    joinableCalls = try values.decodeIfPresent([WireCallInfo].self, forKey: .joinableCalls) ?? []
  }
}

nonisolated struct CreateCallRequest: Encodable, Sendable, Equatable {
  let callerID: String
  let callerName: String
  let roomID: String
  /// Exactly one of these is set: `calleeID` for 1:1, `calleeIDs` for a group.
  let calleeID: String?
  let calleeIDs: [String]?
  let idempotencyKey: String

  private enum CodingKeys: String, CodingKey {
    case callerID = "caller_id", callerName = "caller_name", roomID = "room_id"
    case calleeID = "callee_id", calleeIDs = "callee_ids", idempotencyKey = "idempotency_key"
  }
}

nonisolated struct ActionRequest: Encodable, Sendable {
  let peerID: String
  private enum CodingKeys: String, CodingKey { case peerID = "peer_id" }
}

nonisolated enum CallAction: String, Sendable, Equatable {
  case accept, reject, cancel, join, leave, heartbeat, end
  case endAll = "end-all"
}

nonisolated enum WireDate {
  static func parse(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
  }
}
