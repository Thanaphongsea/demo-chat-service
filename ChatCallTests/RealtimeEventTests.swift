import Foundation
import Testing

@testable import ChatCall

private nonisolated final class FakeRealtime: RealtimeConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]
  private(set) var started = 0
  private(set) var stopped = 0

  func start() async { lock.withLock { started += 1 } }
  func stop() async { lock.withLock { stopped += 1 } }

  func events() -> AsyncStream<RealtimeEvent> {
    let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
    let id = UUID()
    lock.withLock { continuations[id] = continuation }
    continuation.onTermination = { [weak self] _ in
      self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  var subscribers: Int { lock.withLock { continuations.count } }

  func emit(_ event: RealtimeEvent) {
    let targets = lock.withLock { Array(continuations.values) }
    for continuation in targets { continuation.yield(event) }
  }
}

private actor Counter {
  private(set) var value = 0
  func bump() { value += 1 }
}

nonisolated struct RealtimeEventTests {
  private static let me = UserID("alice")

  private func envelope(_ event: String, payload: String) -> Data {
    Data(#"{"Event":"\#(event)","Trace-Id":"t-1","Timestamp":1,"Payload":\#(payload)}"#.utf8)
  }

  // MARK: decoder

  @Test("A new-message envelope decodes the message and its conversation id")
  func decodesNewMessage() throws {
    let data = envelope(
      "onRecvNewMessage",
      payload: """
        {"MsgKey":"k1","From_Account":"bob","To_Account":"alice","ConversationID":"c2c_bob",
         "Type":1,"MsgTimeStamp":5,"MsgBody":[{"MsgType":"TIMTextElem","MsgContent":{"Text":"hi"}}]}
        """)
    guard case .newMessage(let wire)? = RealtimeEventDecoder.decode(data) else {
      Issue.record("not a new message")
      return
    }
    #expect(wire.key == "k1")
    #expect(wire.conversationID == "c2c_bob")
  }

  @Test("Both conversation events decode a list row; read receipts and kicks decode their fields")
  func decodesOtherEvents() throws {
    let row = #"{"conversationID":"c2c_bob","Type":1,"To_Account":"bob","unreadCount":2}"#
    for name in ["onNewConversation", "onConversationChanged"] {
      guard case .conversationChanged(let wire)? = RealtimeEventDecoder.decode(
        envelope(name, payload: row))
      else {
        Issue.record("\(name) did not decode")
        continue
      }
      #expect(wire.unreadCount == 2)
    }
    #expect(
      RealtimeEventDecoder.decode(
        envelope(
          "onRecvC2CReadReceipt",
          payload: #"{"From_Account":"bob","ConversationID":"c2c_bob","MsgReadTime":150}"#))
        == .readReceipt(conversationID: "c2c_bob", readAt: Date(timeIntervalSince1970: 150)))
    #expect(
      RealtimeEventDecoder.decode(
        envelope("onRecvC2CReadReceipt", payload: #"{"From_Account":"bob","MsgReadTime":150}"#))
        == .readReceipt(conversationID: "c2c_bob", readAt: Date(timeIntervalSince1970: 150)))
    #expect(
      RealtimeEventDecoder.decode(envelope("onKickedOffline", payload: #"{"DeviceId":"ios-1"}"#))
        == .kicked(deviceID: "ios-1"))
    #expect(
      RealtimeEventDecoder.decode(envelope("onKickedOffline", payload: "{}"))
        == .kicked(deviceID: nil))
  }

  @Test("Unknown events and unreadable payloads are .unknown; non-envelopes are nil")
  func decodesUnknown() {
    #expect(
      RealtimeEventDecoder.decode(envelope("onTyping", payload: "{}")) == .unknown("onTyping"))
    #expect(
      RealtimeEventDecoder.decode(envelope("onRecvNewMessage", payload: #""oops""#))
        == .unknown("onRecvNewMessage"))
    #expect(
      RealtimeEventDecoder.decode(envelope("onRecvC2CReadReceipt", payload: "{}"))
        == .unknown("onRecvC2CReadReceipt"))
    #expect(RealtimeEventDecoder.decode(Data("not json".utf8)) == nil)
    #expect(RealtimeEventDecoder.decode(Data("{}".utf8)) == nil)
  }

  // MARK: client translation

  private func client(
    kicks: Counter? = nil, deviceID: String? = "ios-1",
    _ handler: @escaping @Sendable (String, [String: Any]) async throws -> String = { _, _ in "{}" }
  ) -> (LiveChatClient, FakeRealtime, StubTransport) {
    let fake = FakeRealtime()
    let (base, transport) = LiveChatClientTests.harness(handler)
    _ = base
    let gateway = GatewayClient(
      configuration: GatewayConfiguration(httpBase: URL(string: "https://gw.example.test")!),
      tokens: StaticTokens(), transport: transport, sleep: { _ in })
    let client = LiveChatClient(
      gateway: gateway, currentUser: { Self.me }, realtime: fake, deviceID: deviceID,
      onKicked: { await kicks?.bump() })
    return (client, fake, transport)
  }

  private func next(_ stream: AsyncStream<ChatEvent>) async -> ChatEvent? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
  }

  private func wireMessage(key: String, from: String, to: String, conversation: String? = nil) -> WireMessage {
    let explicit = conversation.map { #","ConversationID":"\#($0)""# } ?? ""
    let json = #"{"MsgKey":"\#(key)","From_Account":"\#(from)","To_Account":"\#(to)","MsgTimeStamp":9,"MsgBody":[{"MsgType":"TIMTextElem","MsgContent":{"Text":"yo"}}]\#(explicit)}"#
    return try! JSONDecoder().decode(WireMessage.self, from: Data(json.utf8))
  }

  @Test("Subscribing starts the connection; a new message becomes messageInserted with the id the REST reply used")
  func newMessageMapsToInsert() async throws {
    let (client, fake, _) = client()
    let stream = await client.events()
    #expect(fake.started == 1)
    fake.emit(.newMessage(wireMessage(key: "srv-1", from: "bob", to: "alice")))
    guard case .messageInserted(let message)? = await next(stream) else {
      Issue.record("no insert")
      return
    }
    #expect(message.id == MessageID("srv-1"))
    #expect(message.conversationID == ConversationID("c2c_bob"))
    #expect(message.senderID == UserID("bob"))
  }

  @Test("The conversation is derived from addressing when the payload omits it")
  func derivedConversation() {
    let incoming = wireMessage(key: "a", from: "bob", to: "alice")
    let own = wireMessage(key: "b", from: "alice", to: "bob")
    let explicit = wireMessage(key: "c", from: "bob", to: "alice", conversation: "group_g1")
    #expect(ChatMapper.conversationID(of: incoming, me: Self.me) == ConversationID("c2c_bob"))
    #expect(ChatMapper.conversationID(of: own, me: Self.me) == ConversationID("c2c_bob"))
    #expect(ChatMapper.conversationID(of: explicit, me: Self.me) == ConversationID("group_g1"))
  }

  @Test("A direct conversation event becomes conversationUpdated")
  func directConversationEvent() async throws {
    let (client, fake, _) = client()
    let stream = await client.events()
    let row = try JSONDecoder().decode(
      WireConversation.self,
      from: Data(#"{"Type":1,"To_Account":"bob","conversationID":"c2c_bob","unreadCount":4,"showName":"Bob"}"#.utf8))
    fake.emit(.conversationChanged(row))
    guard case .conversationUpdated(let conversation)? = await next(stream) else {
      Issue.record("no update")
      return
    }
    #expect(conversation.unreadCount == 4)
    #expect(conversation.memberIDs == [Self.me, UserID("bob")])
  }

  @Test("A group event fetches its roster once, then reuses it; a failed roster drops only that event")
  func groupConversationEvent() async throws {
    let rosterCalls = Counter()
    let (client, fake, _) = client { operation, _ in
      guard operation == "group_open_http_svc/get_group_member_info" else { return "{}" }
      await rosterCalls.bump()
      return #"{"ErrorCode":0,"MemberNum":3,"MemberList":[{"Member_Account":"alice"},{"Member_Account":"bob"},{"Member_Account":"carol"}]}"#
    }
    let stream = await client.events()
    let row = try JSONDecoder().decode(
      WireConversation.self,
      from: Data(#"{"Type":2,"GroupId":"g1","conversationID":"group_g1","showName":"Team"}"#.utf8))
    fake.emit(.conversationChanged(row))
    fake.emit(.conversationChanged(row))
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<2 {
      guard case .conversationUpdated(let conversation)? = await iterator.next() else {
        Issue.record("missing update")
        return
      }
      #expect(conversation.memberIDs == [Self.me, UserID("bob"), UserID("carol")])
    }
    #expect(await rosterCalls.value == 1)

    let (failing, failingFake, _) = self.client { _, _ in #"{"ErrorCode":10007,"ErrorInfo":"no"}"# }
    let failingStream = await failing.events()
    failingFake.emit(.conversationChanged(row))
    failingFake.emit(.newMessage(wireMessage(key: "after", from: "bob", to: "alice")))
    guard case .messageInserted(let after)? = await next(failingStream) else {
      Issue.record("stream did not continue past the dropped event")
      return
    }
    #expect(after.id == MessageID("after"))
  }

  @Test("A read receipt marks only own messages sent at or before it as delivered, once")
  func readReceiptMarksDelivered() async throws {
    let (client, fake, _) = client { operation, _ in
      #"{"ErrorCode":0,"MsgKey":"m-\#(operation.count)","MsgTime":100}"#
    }
    let stream = await client.events()
    let sent = try await client.send(text: "hello", to: ConversationID("c2c_bob"))
    fake.emit(.readReceipt(conversationID: "c2c_bob", readAt: Date(timeIntervalSince1970: 50)))
    fake.emit(.readReceipt(conversationID: "c2c_bob", readAt: Date(timeIntervalSince1970: 150)))
    fake.emit(.readReceipt(conversationID: "c2c_bob", readAt: Date(timeIntervalSince1970: 200)))
    fake.emit(.newMessage(wireMessage(key: "marker", from: "bob", to: "alice")))
    var iterator = stream.makeAsyncIterator()
    #expect(
      await iterator.next()
        == .deliveryChanged(messageID: sent.id, conversationID: ConversationID("c2c_bob"), state: .delivered))
    guard case .messageInserted(let marker)? = await iterator.next() else {
      Issue.record("an extra delivery event leaked through")
      return
    }
    #expect(marker.id == MessageID("marker"))
  }

  @Test("Unknown events are ignored without ending the stream")
  func unknownIgnored() async throws {
    let (client, fake, _) = client()
    let stream = await client.events()
    fake.emit(.unknown("onTyping"))
    fake.emit(.newMessage(wireMessage(key: "k", from: "bob", to: "alice")))
    guard case .messageInserted? = await next(stream) else {
      Issue.record("stream ended")
      return
    }
  }

  @Test("A kick for this device or the whole account signs out; a kick for another device does not")
  func kicked() async throws {
    let kicks = Counter()
    let (client, fake, _) = client(kicks: kicks, deviceID: "ios-1")
    let stream = await client.events()
    fake.emit(.kicked(deviceID: "other-device"))
    fake.emit(.kicked(deviceID: "ios-1"))
    fake.emit(.kicked(deviceID: nil))
    fake.emit(.newMessage(wireMessage(key: "k", from: "bob", to: "alice")))
    _ = await next(stream)
    #expect(await kicks.value == 2)
  }

  @Test("Reconnecting re-reads the conversation list and publishes it as updates")
  func reconnectResyncs() async throws {
    let (client, fake, _) = client { operation, _ in
      operation == "recentcontact/get_list"
        ? #"{"ErrorCode":0,"CompleteFlag":3,"SessionItem":[\#(LiveChatClientTests.directRow("bob", time: 9, unread: 1))]}"#
        : "{}"
    }
    let stream = await client.events()
    fake.emit(.reconnected)
    guard case .conversationUpdated(let conversation)? = await next(stream) else {
      Issue.record("no resync")
      return
    }
    #expect(conversation.id == ConversationID("c2c_bob"))
    #expect(conversation.unreadCount == 1)
  }

  @Test("Subscribers are independent; ending one leaves the other receiving; stop reaches the socket")
  func independentSubscribers() async throws {
    let (client, fake, _) = client()
    let first = await client.events()
    let second = await client.events()
    #expect(fake.subscribers == 2)
    let secondTask = Task { await next(second) }
    let firstTask = Task { await next(first) }
    firstTask.cancel()
    _ = await firstTask.value
    fake.emit(.newMessage(wireMessage(key: "k", from: "bob", to: "alice")))
    guard case .messageInserted? = await secondTask.value else {
      Issue.record("the surviving subscriber missed an event")
      return
    }
    await client.stopRealtime()
    #expect(fake.stopped == 1)
  }

  @Test("Without a realtime connection the stream simply ends")
  func noRealtime() async {
    let (plain, _) = LiveChatClientTests.harness { _, _ in "{}" }
    #expect(await next(await plain.events()) == nil)
  }
}
