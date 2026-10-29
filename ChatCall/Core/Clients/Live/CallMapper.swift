import Foundation

/// Pure mapping from the VoIP API's call to the viewer's `CallSnapshot`.
/// `status` is the viewer's own view, `group_status` the shared one, `can_join` the server's capability.
nonisolated enum CallMapper {
  static let maxPeople = 16

  /// Nil when the payload cannot describe a call (unknown status, unreadable date).
  static func snapshot(
    _ wire: WireCallInfo, me: UserID, microphone: Bool = true, camera: Bool = true,
    speaker: Bool = true, cameraPosition: CameraPosition = .front
  ) -> CallSnapshot? {
    guard let startedAt = WireDate.parse(wire.createdAt),
      let state = state(of: wire, me: me)
    else { return nil }
    let isGroup = wire.group == true
    let live = [.ringing, .incoming, .active, .reconnecting].contains(state)
    return CallSnapshot(
      id: CallID(wire.callID), conversationID: conversationID(of: wire, me: me),
      kind: isGroup ? .group : .direct, direction: wire.callerID == me.rawValue ? .outgoing : .incoming,
      state: state, participants: participants(of: wire, me: me, presentOnly: live),
      startedAt: startedAt, microphoneEnabled: microphone, cameraEnabled: camera,
      speakerEnabled: speaker, cameraPosition: cameraPosition,
      canJoin: isGroup && state.isTerminal && wire.groupStatus != "ended" && wire.canJoin == true,
      localUserID: me)
  }

  /// `grp_<id>` becomes `group_<id>`; a direct call's conversation is `c2c_<peer>` (room ids are
  /// ambiguous when user ids contain underscores, so the peer comes from the call's own parties).
  static func conversationID(of wire: WireCallInfo, me: UserID) -> ConversationID {
    if wire.group == true {
      let room = wire.roomID
      return ConversationID("group_\(room.hasPrefix("grp_") ? String(room.dropFirst(4)) : room)")
    }
    let peer = wire.callerID == me.rawValue ? (wire.calleeID ?? "") : wire.callerID
    return ConversationID("c2c_\(peer)")
  }

  /// The room a conversation's call lives in: `dm_<min>_<max>` or `grp_<GroupId>`.
  static func roomID(for conversation: ConversationID, me: UserID) -> String? {
    switch LiveChatClient.target(of: conversation) {
    case .direct(let peer): ChatMapper.roomID(me: me, peer: UserID(peer))
    case .group(let id): "grp_\(id)"
    case nil: nil
    }
  }

  private static func state(of wire: WireCallInfo, me: UserID) -> CallState? {
    let isCreator = wire.callerID == me.rawValue
    if wire.group != true {
      switch wire.status {
      case "ringing": return isCreator ? .ringing : .incoming
      case "accepted": return .active
      case "rejected": return .declined
      case "missed": return .missed
      case "cancelled": return isCreator ? .ended : .missed
      case "ended": return .ended
      default: return nil
      }
    }
    if wire.groupStatus == "ended" {
      switch wire.status {
      case "rejected": return .declined
      case "missed": return .missed
      default: return .ended
      }
    }
    switch wire.status {
    case "ringing": return isCreator ? .ringing : .incoming
    case "accepted":
      guard isCreator else { return .active }
      let othersJoined = (wire.participants ?? []).contains {
        $0.userID != me.rawValue && $0.status == "joined"
      }
      return othersJoined ? .active : .ringing
    case "rejected": return .declined
    case "missed": return .missed
    case "ended", "cancelled": return .ended
    default: return nil
    }
  }

  private static func participants(of wire: WireCallInfo, me: UserID, presentOnly: Bool) -> [User] {
    var ids: [String] = []
    if let listed = wire.participants, !listed.isEmpty {
      ids = listed.filter { !presentOnly || $0.status == "joined" || $0.userID == wire.callerID }
        .map(\.userID)
    } else {
      ids = [wire.callerID, wire.calleeID ?? ""]
    }
    if !ids.contains(me.rawValue) { ids.insert(me.rawValue, at: 0) }
    var seen: Set<String> = []
    return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
      let name = id == wire.callerID ? (wire.callerName ?? "").trimmingCharacters(in: .whitespaces) : ""
      let shown = name.isEmpty ? id : name
      return User(id: UserID(id), displayName: shown, initials: String(shown.prefix(2)).uppercased())
    }
  }
}
