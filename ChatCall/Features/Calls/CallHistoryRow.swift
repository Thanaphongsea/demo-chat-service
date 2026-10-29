import SwiftUI

struct CallHistoryRow: View {
  let call: CallSnapshot

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(name: call.displayName, kind: call.kind == .group ? .group : .direct)
      VStack(alignment: .leading, spacing: 4) {
        Text(call.displayName).font(.headline)
        Text(call.historyStatus).foregroundStyle(call.state == .missed ? .red : .secondary)
        Text(call.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "video").foregroundStyle(.secondary).accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
  }
}

extension CallSnapshot {
  var displayName: String {
    let names = participants.filter { $0.id != MockSeed.currentUser.id }.map(\.displayName)
    return kind == .group
      ? "Group call · \(participants.count) people" : names.first ?? "Video call"
  }

  var historyStatus: String {
    switch state {
    case .missed: "Missed"
    case .declined: "Declined"
    case .ended: "Ended"
    default: direction == .incoming ? "Incoming" : "Outgoing"
    }
  }
}
