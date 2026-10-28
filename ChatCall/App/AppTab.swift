nonisolated enum AppTab: Hashable { case chats, calls, profile }

nonisolated enum AppRoute: Hashable {
  case room(ConversationID)
  case call(CallID)
  case compose
  case profile
}
