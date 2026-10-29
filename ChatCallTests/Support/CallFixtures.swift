import Foundation

@testable import ChatCall

/// VoIP API call JSON, as the server renders it for one viewer.
nonisolated enum CallFixtures {
  static func call(
    id: String = "call-1", status: String, group: Bool = false, groupStatus: String? = nil,
    canJoin: Bool? = nil, caller: String = "alice", callee: String = "bob",
    room: String? = nil, participants: [(String, String)]? = nil
  ) -> String {
    let roomID = room ?? (group ? "grp_g1" : "dm_alice_bob")
    let list = participants.map {
      ",\"participants\":["
        + $0.map { #"{"user_id":"\#($0.0)","status":"\#($0.1)"}"# }.joined(separator: ",") + "]"
    } ?? ""
    let flags =
      (group ? #","group":true"# : "") + (groupStatus.map { #","group_status":"\#($0)""# } ?? "")
      + (canJoin.map { #","can_join":\#($0)"# } ?? "")
    return """
      {"call_id":"\(id)","room_id":"\(roomID)","caller_id":"\(caller)","callee_id":"\(group ? "" : callee)",
       "caller_name":"\(caller.capitalized)","status":"\(status)","created_at":"2026-10-22T09:00:00Z"\(flags)\(list)}
      """
  }

  static func inbox(calls: [String] = [], joinable: [String] = []) -> String {
    #"{"calls":[\#(calls.joined(separator: ","))],"joinable_calls":[\#(joinable.joined(separator: ","))]}"#
  }
}

/// Scripted routes keyed `"METHOD /path"`; each route pops its replies and repeats the last one.
nonisolated final class Router: @unchecked Sendable {
  private let lock = NSLock()
  private var routes: [String: [StubReply]] = [:]

  func set(_ key: String, _ replies: StubReply...) { lock.withLock { routes[key] = replies } }

  func ok(_ key: String, _ json: String) { set(key, StubReply(200, Data(json.utf8))) }

  func reply(for request: URLRequest) -> StubReply {
    let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
    return lock.withLock {
      guard var queue = routes[key], !queue.isEmpty else { return StubReply(404, Data("{}".utf8)) }
      let next = queue.count > 1 ? queue.removeFirst() : queue[0]
      routes[key] = queue
      return next
    }
  }
}

nonisolated final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
  var date: Date { lock.withLock { current } }
  func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

nonisolated final class Tally: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int { lock.withLock { value += 1; return value } }
  var count: Int { lock.withLock { value } }
}
