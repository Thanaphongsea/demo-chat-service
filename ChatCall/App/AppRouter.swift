import Observation

enum ComposeSheet: Identifiable {
  case newConversation(NewConversationStore)

  var id: ObjectIdentifier {
    switch self {
    case .newConversation(let store): ObjectIdentifier(store)
    }
  }
}

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
  let callStore: CallStore
  var presentedSheet: ComposeSheet?
  private let chatClient: any ChatClient
  @ObservationIgnored private var rooms: [ConversationID: ChatRoomStore] = [:]

  init(
    chatClient: any ChatClient, callClient: any CallClient = MockCallClient(),
    demoCalls: Bool = true
  ) {
    self.chatClient = chatClient
    conversations = ConversationListStore(client: chatClient)
    callStore = CallStore(client: callClient, chatClient: chatClient, demoEnabled: demoCalls)
  }

  func presentComposer(currentUserID: UserID) {
    guard presentedSheet == nil else { return }
    presentedSheet = .newConversation(
      NewConversationStore(client: chatClient, currentUserID: currentUserID))
  }

  func room(for id: ConversationID, currentUserID: UserID) -> ChatRoomStore {
    if let store = rooms[id] { return store }
    let store = ChatRoomStore(conversationID: id, currentUserID: currentUserID, client: chatClient)
    rooms[id] = store
    return store
  }

  func requestVideo(in id: ConversationID) { chats.routes.append(.startCall(id)) }

  func finishCompose(_ conversation: Conversation, from store: NewConversationStore) {
    guard case .newConversation(let activeStore) = presentedSheet, activeStore === store,
      store.createdConversation == conversation
    else { return }
    conversations.includeCreated(conversation)
    presentedSheet = nil
    selectedTab = .chats
    chats.routes.append(.room(conversation.id))
  }

  func reset() {
    callStore.reset()
    for room in rooms.values { room.cancel() }
    rooms = [:]
    if case .newConversation(let store) = presentedSheet { store.cancel() }
    presentedSheet = nil
    conversations.reset()
    chats = RouterPath()
    calls = RouterPath()
    profile = RouterPath()
    selectedTab = .chats
  }
}
