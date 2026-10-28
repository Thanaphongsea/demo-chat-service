import Foundation
import Observation

@MainActor
@Observable
final class NewConversationStore {
  enum Step: Hashable { case members, groupDetails }
  enum Failure: Equatable {
    case chat(ChatError)
    case unavailable
  }
  enum State: Equatable {
    case loading, loaded
    case failed(Failure)
  }

  var searchText = ""
  var groupName = ""
  var step: Step = .members
  private(set) var state: State = .loading
  private(set) var selectedUsers: [User] = []
  private(set) var isCreating = false
  private(set) var failure: Failure?
  private(set) var createdConversation: Conversation?
  private(set) var users: [User] = []
  @ObservationIgnored private let client: any ChatClient
  @ObservationIgnored private let currentUserID: UserID
  @ObservationIgnored private var loadTask: Task<[User], any Error>?
  @ObservationIgnored private var createTask: Task<Conversation, any Error>?
  @ObservationIgnored private var revision = 0

  var visibleUsers: [User] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return users.filter { query.isEmpty || $0.displayName.localizedStandardContains(query) }
  }
  var canContinue: Bool {
    state == .loaded && !selectedUsers.isEmpty && !isCreating && createdConversation == nil
  }
  var canCreateGroup: Bool {
    canContinue && selectedUsers.count >= 2
      && !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init(client: any ChatClient, currentUserID: UserID) {
    self.client = client
    self.currentUserID = currentUserID
  }

  func load() async {
    guard loadTask == nil, !Task.isCancelled else { return }
    let attempt = revision
    state = .loading
    let operation = Task { try await client.listUsers() }
    loadTask = operation
    await withTaskCancellationHandler {
      do {
        let roster = try await operation.value
        try Task.checkCancellation()
        guard attempt == revision else { return }
        var seen: Set<UserID> = [currentUserID]
        users = roster.filter { seen.insert($0.id).inserted }
        state = .loaded
      } catch {
        guard attempt == revision, !Task.isCancelled, !(error is CancellationError) else { return }
        state = .failed(Self.failure(for: error))
      }
    } onCancel: {
      operation.cancel()
    }
    if attempt == revision { loadTask = nil }
  }

  func toggle(_ user: User) {
    guard !isCreating, createdConversation == nil,
      let member = users.first(where: { $0.id == user.id })
    else { return }
    if let index = selectedUsers.firstIndex(where: { $0.id == user.id }) {
      selectedUsers.remove(at: index)
    } else {
      selectedUsers.append(member)
    }
    failure = nil
  }

  func proceed() async {
    guard canContinue, !Task.isCancelled else { return }
    if selectedUsers.count == 1, let user = selectedUsers.first {
      await create { [client] in try await client.createDirect(with: user.id) }
    } else {
      failure = nil
      step = .groupDetails
    }
  }

  func createGroup() async {
    guard !isCreating, createdConversation == nil, !Task.isCancelled else { return }
    guard selectedUsers.count >= 2 else {
      failure = .chat(.invalidMembers)
      return
    }
    let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      failure = .chat(.groupNameRequired)
      return
    }
    let members = selectedUsers.map(\.id)
    // The client adds the current session user; this picker supplies unique other members only.
    await create { [client] in try await client.createGroup(name: name, members: members) }
  }

  func cancel() {
    revision += 1
    loadTask?.cancel()
    loadTask = nil
    createTask?.cancel()
    createTask = nil
    users = []
    selectedUsers = []
    searchText = ""
    groupName = ""
    step = .members
    isCreating = false
    failure = nil
    createdConversation = nil
    state = .loading
  }

  private func create(_ action: @escaping @Sendable () async throws -> Conversation) async {
    let attempt = revision
    isCreating = true
    failure = nil
    let operation = Task { try await action() }
    createTask = operation
    await withTaskCancellationHandler {
      do {
        let conversation = try await operation.value
        try Task.checkCancellation()
        guard attempt == revision else { return }
        createdConversation = conversation
      } catch {
        guard attempt == revision, !Task.isCancelled, !(error is CancellationError) else { return }
        failure = Self.failure(for: error)
      }
    } onCancel: {
      operation.cancel()
    }
    if attempt == revision {
      isCreating = false
      createTask = nil
    }
  }

  private static func failure(for error: any Error) -> Failure {
    if let error = error as? ChatError { return .chat(error) }
    return .unavailable
  }
}
