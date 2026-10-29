import Foundation
import Observation

struct RoomMessage: Identifiable, Equatable {
  enum Status: Int { case sending, sent, delivered, failed }
  let id: MessageID
  var message: Message
  var status: Status
}

struct MessageSection: Identifiable {
  let id: Date
  let messages: [RoomMessage]
}

@MainActor
@Observable
final class ChatRoomStore {
  enum State: Equatable {
    case loading, loaded, empty
    case failed(String)
  }

  var draft = ""
  private(set) var state: State = .loading
  private var messages: [RoomMessage] = []
  private var users: [User] = []
  let conversationID: ConversationID
  let currentUserID: UserID
  @ObservationIgnored private let client: any ChatClient
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var loadTask: Task<([Message], [User]), any Error>?
  @ObservationIgnored private var eventsTask: Task<Void, Never>?
  @ObservationIgnored private var sendTasks: [MessageID: Task<Void, Never>] = [:]
  @ObservationIgnored private var deferredInserts: [MessageID: Message] = [:]
  @ObservationIgnored private var deliveries: [MessageID: RoomMessage.Status] = [:]

  var orderedMessages: [RoomMessage] {
    messages.sorted {
      $0.message.sentAt == $1.message.sentAt
        ? $0.message.id.rawValue < $1.message.id.rawValue : $0.message.sentAt < $1.message.sentAt
    }
  }

  var sections: [MessageSection] {
    let days = Dictionary(grouping: orderedMessages) { calendar.startOfDay(for: $0.message.sentAt) }
    return days.keys.sorted().map { MessageSection(id: $0, messages: days[$0] ?? []) }
  }

  var scrollTargetID: MessageID? { orderedMessages.last?.id }
  var canSend: Bool {
    (state == .loaded || state == .empty)
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func senderName(for id: UserID) -> String {
    users.first { $0.id == id }?.displayName ?? "Unknown member"
  }

  init(
    conversationID: ConversationID, currentUserID: UserID, client: any ChatClient,
    calendar: Calendar = .current, now: @escaping () -> Date = { Date() }
  ) {
    self.conversationID = conversationID
    self.currentUserID = currentUserID
    self.client = client
    self.calendar = calendar
    self.now = now
  }

  func load() async {
    guard loadTask == nil, !Task.isCancelled else { return }
    let attempt = revision
    state = .loading
    let operation = Task {
      async let messages = client.messages(in: conversationID)
      let users = (try? await client.listUsers()) ?? []
      return try await (messages, users)
    }
    loadTask = operation
    await withTaskCancellationHandler {
      do {
        let (snapshot, users) = try await operation.value
        try Task.checkCancellation()
        guard attempt == revision else { return }
        self.users = users
        for message in snapshot { insert(message) }
        updateState()
      } catch {
        guard attempt == revision, !Task.isCancelled, !(error is CancellationError) else { return }
        state = .failed("Unable to load messages. Please try again.")
      }
    } onCancel: {
      operation.cancel()
    }
    if attempt == revision { loadTask = nil }
  }

  func start() {
    guard eventsTask == nil else { return }
    let attempt = revision
    eventsTask = Task { [weak self, client] in
      // Buffer events before requesting the snapshot to close the subscribe/load race.
      let events = await client.events()
      await self?.load()
      for await event in events {
        guard !Task.isCancelled else { return }
        self?.reduce(event, revision: attempt)
      }
    }
  }

  func send() {
    guard canSend else { return }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = MessageID("local-\(UUID().uuidString)")
    let message = Message(
      id: id, conversationID: conversationID, senderID: currentUserID,
      text: text, sentAt: now(), deliveryState: .sending)
    messages.append(RoomMessage(id: id, message: message, status: .sending))
    draft = ""
    updateState()
    submit(id, text: text)
  }

  func retry(_ id: MessageID) {
    guard let index = messages.firstIndex(where: { $0.id == id }),
      messages[index].status == .failed, sendTasks[id] == nil
    else { return }
    messages[index].status = .sending
    submit(id, text: messages[index].message.text)
  }

  func cancel() {
    revision += 1
    eventsTask?.cancel()
    eventsTask = nil
    loadTask?.cancel()
    loadTask = nil
    for task in sendTasks.values { task.cancel() }
    sendTasks = [:]
    deferredInserts = [:]
    deliveries = [:]
    messages = []
    users = []
    draft = ""
    state = .loading
  }

  private func submit(_ id: MessageID, text: String) {
    let attempt = revision
    sendTasks[id] = Task { [weak self, client, conversationID] in
      do {
        let message = try await client.send(text: text, to: conversationID)
        try Task.checkCancellation()
        self?.completeSend(id, result: .success(message), revision: attempt)
      } catch {
        guard !Task.isCancelled else { return }
        self?.completeSend(id, result: .failure(error), revision: attempt)
      }
    }
  }

  private func completeSend(
    _ id: MessageID, result: Result<Message, any Error>, revision attempt: Int
  ) {
    guard attempt == revision, let index = messages.firstIndex(where: { $0.id == id }) else {
      return
    }
    switch result {
    case .success(let message) where message.conversationID == conversationID:
      messages[index].message = message
      messages[index].status = latestStatus(for: message)
      deferredInserts.removeValue(forKey: message.id)
    default:
      messages[index].status = .failed
    }
    sendTasks.removeValue(forKey: id)
    // Own inserts may arrive before send returns its server ID. Reconcile by that ID,
    // never by text, so two identical concurrent drafts remain distinct messages.
    if sendTasks.isEmpty {
      let buffered = deferredInserts.values
      deferredInserts = [:]
      for message in buffered { insert(message) }
    }
  }

  private func reduce(_ event: ChatEvent, revision attempt: Int) {
    guard attempt == revision else { return }
    switch event {
    case .messageInserted(let message):
      guard message.conversationID == conversationID else { return }
      if message.senderID == currentUserID, !sendTasks.isEmpty {
        deferredInserts[message.id] = message
      } else {
        insert(message)
        updateState()
      }
    case .deliveryChanged(let id, let room, let delivery):
      guard room == conversationID else { return }
      let status = Self.status(delivery)
      deliveries[id] = maxStatus(deliveries[id] ?? .sending, status)
      if let index = messages.firstIndex(where: { $0.message.id == id }) {
        messages[index].status = maxStatus(messages[index].status, status)
      }
    case .conversationUpdated:
      break
    }
  }

  private func insert(_ message: Message) {
    guard message.conversationID == conversationID else { return }
    if let index = messages.firstIndex(where: { $0.message.id == message.id }) {
      messages[index].status = maxStatus(messages[index].status, latestStatus(for: message))
    } else {
      messages.append(
        RoomMessage(id: message.id, message: message, status: latestStatus(for: message)))
    }
  }

  private func latestStatus(for message: Message) -> RoomMessage.Status {
    maxStatus(Self.status(message.deliveryState), deliveries[message.id] ?? .sending)
  }

  private func maxStatus(
    _ left: RoomMessage.Status, _ right: RoomMessage.Status
  ) -> RoomMessage.Status {
    left.rawValue >= right.rawValue ? left : right
  }

  private static func status(_ delivery: DeliveryState) -> RoomMessage.Status {
    switch delivery {
    case .sending: .sending
    case .sent: .sent
    case .delivered: .delivered
    }
  }

  private func updateState() { state = messages.isEmpty ? .empty : .loaded }
}
