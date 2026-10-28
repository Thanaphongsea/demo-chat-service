import SwiftUI

struct ConversationListView: View {
  @Bindable var store: ConversationListStore
  var compose: (() -> Void)?

  var body: some View {
    Group {
      switch store.state {
      case .loading:
        ProgressView("Loading chats…")
          .accessibilityIdentifier("conversations.loading")
      case .failed(let message):
        AsyncStateView(
          title: "Couldn’t load chats", systemImage: "wifi.exclamationmark", message: message,
          identifier: "conversations.error", retry: { Task { await store.load() } })
      case .empty:
        AsyncStateView(
          title: "No chats yet", systemImage: "bubble.left.and.bubble.right",
          message: "Your conversations will appear here.", identifier: "conversations.empty")
      case .loaded:
        if store.visibleConversations.isEmpty {
          AsyncStateView(
            title: "No matching chats", systemImage: "magnifyingglass",
            message: "Try a different name or message.", identifier: "conversations.noResults")
        } else {
          List(store.visibleConversations) { conversation in
            NavigationLink(value: AppRoute.room(conversation.id)) {
              ConversationRow(conversation: conversation)
            }
            .accessibilityIdentifier("conversations.room.\(conversation.id.rawValue)")
            .listRowBackground(Color(.secondarySystemGroupedBackground))
          }
          .listStyle(.insetGrouped)
          .scrollContentBackground(.hidden)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.screenBackground)
    .navigationTitle("Chats")
    .toolbar {
      if let compose {
        ToolbarItem(placement: .topBarTrailing) {
          Button("New chat", systemImage: "square.and.pencil", action: compose)
            .accessibilityIdentifier("conversations.compose")
        }
      }
    }
    .searchable(
      text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Search chats"
    )
    .task { store.start() }
  }
}

#Preview("Populated") {
  ConversationListPreview(fixture: .populated)
}
#Preview("Empty") {
  ConversationListPreview(fixture: .empty)
}
#Preview("Loading") {
  ConversationListPreview(fixture: .loading)
}
#Preview("Failed") {
  ConversationListPreview(fixture: .failed)
}
#Preview("Dark") {
  ConversationListPreview(fixture: .populated).preferredColorScheme(.dark)
}
#Preview("Large text") {
  ConversationListPreview(fixture: .populated).dynamicTypeSize(.accessibility3)
}
