import SwiftUI

struct MessageBubble: View {
  let row: RoomMessage
  let isOutgoing: Bool
  let senderName: String
  var showsSender = false
  var retry: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 32) {
      if isOutgoing { Spacer(minLength: 0) }
      VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
        if showsSender && !isOutgoing {
          Text(senderName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        Text(row.message.text)
          .font(.body)
          .textSelection(.enabled)
          .foregroundStyle(isOutgoing ? Color(.systemBackground) : Color(.label))
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(
            isOutgoing ? Color(.label) : Color(.secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18)
          )
          .accessibilityIdentifier("room.message.\(row.id.rawValue)")
        metadata
        if isOutgoing && row.status == .failed {
          Button("Retry message", systemImage: "arrow.clockwise", action: retry)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityHint("Sends this message again")
        }
      }
      if !isOutgoing { Spacer(minLength: 0) }
    }
  }

  private var metadata: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        timestamp
        delivery
      }
      VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
        timestamp
        delivery
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var timestamp: some View {
    Text(row.message.sentAt, format: .dateTime.hour().minute())
  }

  @ViewBuilder
  private var delivery: some View {
    if isOutgoing {
      Text(statusLabel)
        .foregroundStyle(row.status == .failed ? Color.red : Color.secondary)
        .accessibilityIdentifier("room.delivery.\(row.id.rawValue)")
    }
  }

  private var statusLabel: String {
    switch row.status {
    case .sending: "Sending"
    case .sent: "Sent"
    case .delivered: "Delivered"
    case .failed: "Failed to send"
    }
  }
}

#Preview("Failed send") {
  MessageBubble(
    row: RoomMessage(
      id: MessageID("preview-failed"), message: ChatRoomPreview.outgoing, status: .failed),
    isOutgoing: true, senderName: "You", retry: {}
  )
  .padding()
  .background(AppTheme.screenBackground)
}
