import Foundation

/// What the realtime socket delivers, decoded from the `{Event, Payload}` publication envelope.
nonisolated enum RealtimeEvent: Equatable, Sendable {
  case newMessage(WireMessage)
  /// `onNewConversation` and `onConversationChanged`: the payload is a conversation-list row.
  case conversationChanged(WireConversation)
  case readReceipt(conversationID: String, readAt: Date)
  /// The account (or one device of it) was signed out by the server.
  case kicked(deviceID: String?)
  /// The socket connected again after a drop; anything published meanwhile was missed.
  case reconnected
  /// An event this client does not render, or one whose payload was unreadable.
  case unknown(String)
}

nonisolated enum RealtimeEventDecoder {
  private struct Name: Decodable { let event: String?
    private enum CodingKeys: String, CodingKey { case event = "Event" }
  }
  private struct Wrapper<Payload: Decodable>: Decodable { let payload: Payload
    private enum CodingKeys: String, CodingKey { case payload = "Payload" }
  }
  private struct ReadReceipt: Decodable {
    let from: String?
    let conversationID: String?
    let readTime: Double?
    private enum CodingKeys: String, CodingKey {
      case from = "From_Account", conversationID = "ConversationID", readTime = "MsgReadTime"
    }
  }
  private struct Kick: Decodable { let deviceID: String?
    private enum CodingKeys: String, CodingKey { case deviceID = "DeviceId" }
  }

  /// Nil only when the data is not an event envelope at all; unknown or malformed events are `.unknown`.
  static func decode(_ data: Data) -> RealtimeEvent? {
    let decoder = JSONDecoder()
    guard let name = (try? decoder.decode(Name.self, from: data))?.event, !name.isEmpty else {
      return nil
    }
    switch name {
    case "onRecvNewMessage":
      return (try? decoder.decode(Wrapper<WireMessage>.self, from: data)).map { .newMessage($0.payload) }
        ?? .unknown(name)
    case "onNewConversation", "onConversationChanged":
      return (try? decoder.decode(Wrapper<WireConversation>.self, from: data)).map {
        .conversationChanged($0.payload)
      } ?? .unknown(name)
    case "onRecvC2CReadReceipt":
      guard let receipt = (try? decoder.decode(Wrapper<ReadReceipt>.self, from: data))?.payload,
        let readTime = receipt.readTime
      else { return .unknown(name) }
      let conversation = receipt.conversationID.flatMap { $0.isEmpty ? nil : $0 }
        ?? receipt.from.map { "c2c_\($0)" }
      guard let conversation else { return .unknown(name) }
      return .readReceipt(conversationID: conversation, readAt: Date(timeIntervalSince1970: readTime))
    case "onKickedOffline":
      let device = (try? decoder.decode(Wrapper<Kick>.self, from: data))?.payload.deviceID
      return .kicked(deviceID: device.flatMap { $0.isEmpty ? nil : $0 })
    default:
      return .unknown(name)
    }
  }
}

/// A shared socket carrying one user's events. Each `events()` call is an independent subscription.
nonisolated protocol RealtimeConnection: Sendable {
  /// Connects if needed; safe to call repeatedly.
  func start() async
  func stop() async
  /// Registers immediately, so nothing emitted after the call returns is missed.
  func events() -> AsyncStream<RealtimeEvent>
}
