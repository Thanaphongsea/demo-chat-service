import SwiftUI

struct ConversationRow: View {
  let conversation: Conversation

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(name: conversation.name, kind: conversation.kind)
      VStack(alignment: .leading, spacing: 6) {
        Text(conversation.name)
          .font(.headline)
          .foregroundStyle(.primary)
        Text(conversation.lastMessage?.text ?? "Start a conversation")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(conversation.kind == .direct ? "Direct" : "Group")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color(.tertiarySystemFill), in: Capsule())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 8) {
        Text(conversation.updatedAt, format: .dateTime.hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
        UnreadBadge(count: conversation.unreadCount)
          .accessibilityIdentifier("conversations.unread.\(conversation.id.rawValue)")
      }
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }
}
