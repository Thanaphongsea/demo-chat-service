import Observation

@MainActor
@Observable
final class RouterPath {
  var routes: [AppRoute] = []
}

@MainActor
@Observable
final class AppRouter {
  var selectedTab: AppTab = .chats
  var chats = RouterPath()
  var calls = RouterPath()
  var profile = RouterPath()
  let conversations: ConversationListStore

  init(chatClient: any ChatClient) {
    conversations = ConversationListStore(client: chatClient)
  }

  func reset() {
    conversations.reset()
    chats = RouterPath()
    calls = RouterPath()
    profile = RouterPath()
    selectedTab = .chats
  }
}
