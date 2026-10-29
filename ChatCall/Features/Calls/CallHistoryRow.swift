import SwiftUI

struct CallHistoryRow: View {
  let call: CallSnapshot
  var join: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(name: call.displayName, kind: call.kind == .group ? .group : .direct)
      VStack(alignment: .leading, spacing: 4) {
        Text(call.displayName).font(.headline)
        Text(call.historyStatus).foregroundStyle(call.state == .missed ? .red : .secondary)
        Text(call.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if call.canJoin, let join {
        Button(call.joinTitle, action: join).buttonStyle(.borderedProminent)
          .accessibilityIdentifier("calls.join")
      } else {
        Image(systemName: "video").foregroundStyle(.secondary).accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: call.canJoin ? .contain : .combine)
  }
}

extension CallSnapshot {
  var displayName: String {
    let names = participants.filter { $0.id != localUserID }.map(\.displayName)
    return kind == .group
      ? "Group call · \(participants.count) people" : names.first ?? "Video call"
  }

  /// A missed call is joined for the first time; a declined or left one is rejoined.
  var joinTitle: String { state == .missed ? "Join" : "Rejoin" }

  var historyStatus: String {
    switch state {
    case .missed: "Missed"
    case .declined: "Declined"
    case .ended: "Ended"
    default: direction == .incoming ? "Incoming" : "Outgoing"
    }
  }
}
