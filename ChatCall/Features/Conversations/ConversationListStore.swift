import Foundation
import Observation

@MainActor
@Observable
final class ConversationListStore {
  enum State: Equatable {
    case loading, loaded, empty
    case failed(String)
  }

  private(set) var state: State = .loading
  private(set) var conversations: [Conversation] = []
  var searchText = ""
  @ObservationIgnored private let client: any ChatClient
  @ObservationIgnored private var eventsTask: Task<Void, Never>?
  @ObservationIgnored private var loadTask: Task<[Conversation], any Error>?
  @ObservationIgnored private var updatesDuringLoad: [ConversationID: Conversation] = [:]
  @ObservationIgnored private var revision = 0

  var visibleConversations: [Conversation] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return conversations.filter {
      query.isEmpty || $0.name.localizedStandardContains(query)
        || ($0.lastMessage?.text.localizedStandardContains(query) ?? false)
    }.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id.rawValue < $1.id.rawValue : $0.updatedAt > $1.updatedAt
    }
  }

  var totalUnreadCount: Int { conversations.reduce(0) { $0 + max(0, $1.unreadCount) } }

  init(client: any ChatClient) { self.client = client }

  func load() async {
    guard loadTask == nil, !Task.isCancelled else { return }
    let attempt = revision
    updatesDuringLoad = [:]
    state = .loading
    let operation = Task { try await client.listConversations() }
    loadTask = operation
    await withTaskCancellationHandler {
      do {
        let rooms = try await operation.value
        try Task.checkCancellation()
        guard attempt == revision else { return }
        // Events received after this snapshot began take precedence over its older values.
        conversations =
          rooms.filter { updatesDuringLoad[$0.id] == nil }
          + Array(updatesDuringLoad.values)
        state = conversations.isEmpty ? .empty : .loaded
      } catch {
        guard attempt == revision, !Task.isCancelled, !(error is CancellationError) else { return }
        state = .failed("Unable to load chats. Please try again.")
      }
    } onCancel: {
      operation.cancel()
    }
    if attempt == revision {
      loadTask = nil
      updatesDuringLoad = [:]
    }
  }

  func start() {
    guard eventsTask == nil else { return }
    let attempt = revision
    eventsTask = Task { [weak self, client] in
      // Subscribe before the snapshot so updates during loading are buffered and applied afterward.
      let events = await client.events()
      await self?.load()
      for await event in events {
        guard !Task.isCancelled else { return }
        self?.reduce(event, revision: attempt)
      }
    }
  }

  func reset() {
    revision += 1
    eventsTask?.cancel()
    eventsTask = nil
    loadTask?.cancel()
    loadTask = nil
    updatesDuringLoad = [:]
    conversations = []
    searchText = ""
    state = .loading
  }

  private func reduce(_ event: ChatEvent, revision attempt: Int) {
    guard attempt == revision else { return }
    // The repository publishes authoritative previews and unread counts as conversation updates.
    guard case .conversationUpdated(let conversation) = event else { return }
    if loadTask != nil { updatesDuringLoad[conversation.id] = conversation }
    if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
      conversations[index] = conversation
    } else {
      conversations.append(conversation)
    }
    state = .loaded
  }
}
