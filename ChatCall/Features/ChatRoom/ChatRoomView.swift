import SwiftUI

struct ChatRoomView: View {
  @Bindable var store: ChatRoomStore
  let title: String
  let kind: ConversationKind
  var video: () -> Void

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(AppTheme.screenBackground)
      .safeAreaInset(edge: .bottom) {
        MessageComposer(text: $store.draft, canSend: store.canSend, send: store.send)
          .disabled(store.state == .loading || isLoadFailure)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Start video call", systemImage: "video", action: video)
            .accessibilityIdentifier("room.video")
        }
      }
      .task { store.start() }
      .onDisappear { store.cancel() }
  }

  private var isLoadFailure: Bool {
    if case .failed = store.state { return true }
    return false
  }

  @ViewBuilder
  private var content: some View {
    switch store.state {
    case .loading:
      ProgressView("Loading messages…").accessibilityIdentifier("room.loading")
    case .failed(let message):
      ContentUnavailableView {
        Label("Couldn’t load messages", systemImage: "wifi.exclamationmark")
          .accessibilityIdentifier("room.error")
      } description: {
        Text(message)
      } actions: {
        Button("Try again") { Task { await store.load() } }
          .accessibilityIdentifier("room.retryLoad")
          .buttonStyle(.borderedProminent)
      }
    case .empty:
      ContentUnavailableView(
        "No messages yet", systemImage: "bubble.left.and.bubble.right",
        description: Text("Send a message to start the conversation.")
      )
      .accessibilityIdentifier("room.empty")
    case .loaded:
      timeline
    }
  }

  private var timeline: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 16) {
          ForEach(store.sections) { section in
            // One child per day keeps lazy identity stable when acknowledgment changes a date.
            VStack(spacing: 16) {
              DateSeparator(date: section.id)
              ForEach(section.messages) { row in
                MessageBubble(
                  row: row, isOutgoing: row.message.senderID == store.currentUserID,
                  senderName: kind == .group ? "Group member" : title,
                  showsSender: kind == .group, retry: { store.retry(row.id) }
                )
                .id(row.id)
              }
            }
          }
        }
        .padding(16)
      }
      .defaultScrollAnchor(.bottom)
      .scrollDismissesKeyboard(.interactively)
      .accessibilityIdentifier("room.messages")
      .onChange(of: store.scrollTargetID) { _, id in
        if let id { proxy.scrollTo(id, anchor: .bottom) }
      }
    }
  }
}

#Preview("Direct · incoming, outgoing, long text") {
  ChatRoomPreview(kind: .direct)
}
#Preview("Group") {
  ChatRoomPreview(kind: .group)
}
#Preview("Dark") {
  ChatRoomPreview(kind: .direct).preferredColorScheme(.dark)
}
#Preview("Accessibility text") {
  ChatRoomPreview(kind: .group).dynamicTypeSize(.accessibility3)
}
#Preview("Empty") {
  ChatRoomPreview(fixture: .empty)
}
#Preview("Loading") {
  ChatRoomPreview(fixture: .loading)
}
#Preview("Load error") {
  ChatRoomPreview(fixture: .failed)
}
