nonisolated enum AppTab: Hashable { case chats, calls, profile }

nonisolated enum AppRoute: Hashable {
  case room(ConversationID)
  case call(CallID)
  case startCall(ConversationID)
  case compose
  case profile
}
