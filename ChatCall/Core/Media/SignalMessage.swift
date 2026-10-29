import Foundation

nonisolated struct SessionDescription: Equatable, Sendable {
  /// `offer` or `answer`.
  let type: String
  let sdp: String
}

nonisolated struct IceCandidate: Equatable, Sendable {
  let candidate: String
  let sdpMid: String?
  let sdpMLineIndex: Int32?
}

/// The SFU signalling protocol. Never carries a `to` field: the server routes by call.
nonisolated enum SignalMessage: Equatable, Sendable {
  case offer(SessionDescription)
  case answer(SessionDescription)
  case ice(IceCandidate)
  case roomPeers([String])
  case peerJoined(String)
  case peerLeft(String)
  /// User ids whose video to receive: `[]` none, `nil` everyone.
  case videoSubscriptions([String]?)
  case error(String)
  case unknown(String)

  /// Nil only when the data is not a JSON object with a `type`.
  static func decode(_ data: Data) -> SignalMessage? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = object["type"] as? String
    else { return nil }
    switch type {
    case "offer", "answer":
      guard let body = object["sdp"] as? [String: Any], let sdp = body["sdp"] as? String else {
        return .unknown(type)
      }
      let description = SessionDescription(type: type, sdp: sdp)
      return type == "offer" ? .offer(description) : .answer(description)
    case "ice":
      guard let body = object["candidate"] as? [String: Any],
        let candidate = body["candidate"] as? String
      else { return .unknown(type) }
      return .ice(
        IceCandidate(
          candidate: candidate, sdpMid: body["sdpMid"] as? String,
          sdpMLineIndex: (body["sdpMLineIndex"] as? Int).map { Int32($0) }))
    case "room_peers":
      return .roomPeers((object["peers"] as? [String]) ?? [])
    case "peer_joined":
      return (object["from"] as? String).map(SignalMessage.peerJoined) ?? .unknown(type)
    case "peer_left":
      return (object["from"] as? String).map(SignalMessage.peerLeft) ?? .unknown(type)
    case "error":
      return .error((object["error"] as? String) ?? "")
    default:
      return .unknown(type)
    }
  }

  func encoded() throws -> Data {
    let object: [String: Any]
    switch self {
    case .offer(let description), .answer(let description):
      object = [
        "type": description.type, "sdp": ["type": description.type, "sdp": description.sdp]
      ]
    case .ice(let candidate):
      var body: [String: Any] = ["candidate": candidate.candidate]
      body["sdpMid"] = candidate.sdpMid.map { $0 as Any } ?? NSNull()
      body["sdpMLineIndex"] = candidate.sdpMLineIndex.map { Int($0) as Any } ?? NSNull()
      object = ["type": "ice", "candidate": body]
    case .videoSubscriptions(let peers):
      object = ["type": "video_subscriptions", "video_peers": peers.map { $0 as Any } ?? NSNull()]
    case .roomPeers, .peerJoined, .peerLeft, .error, .unknown:
      throw SignalError.notSendable
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

nonisolated enum SignalError: Error, Equatable, Sendable {
  case notSendable
  case notConnected
  case closed
}

/// One authenticated WebSocket to the SFU for one call.
nonisolated protocol SignalingTransport: Sendable {
  /// Opens the socket with `Authorization: Bearer <token>`; the token is never put in the URL.
  func connect(url: URL, token: String) async throws
  func send(_ message: SignalMessage) async throws
  /// Decoded messages; finishes when the socket closes or fails (throwing on failure).
  var messages: AsyncThrowingStream<SignalMessage, Error> { get }
  func close() async
}

/// The real transport over `URLSessionWebSocketTask`; ping/pong is answered by the system.
nonisolated final class URLSessionSignalingTransport: SignalingTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionWebSocketTask?
  private let session: URLSession
  private let continuation: AsyncThrowingStream<SignalMessage, Error>.Continuation
  let messages: AsyncThrowingStream<SignalMessage, Error>

  init(session: URLSession = .shared) {
    self.session = session
    (messages, continuation) = AsyncThrowingStream<SignalMessage, Error>.makeStream()
  }

  func connect(url: URL, token: String) async throws {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    lock.withLock { self.task = task }
    task.resume()
    Task { await self.receiveLoop(task) }
  }

  func send(_ message: SignalMessage) async throws {
    guard let task = lock.withLock({ task }) else { throw SignalError.notConnected }
    let data = try message.encoded()
    try await task.send(.string(String(decoding: data, as: UTF8.self)))
  }

  func close() async {
    lock.withLock { task }?.cancel(with: .normalClosure, reason: nil)
    continuation.finish()
  }

  private func receiveLoop(_ task: URLSessionWebSocketTask) async {
    do {
      while true {
        let frame = try await task.receive()
        let data: Data
        switch frame {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: continue
        }
        if let message = SignalMessage.decode(data) { continuation.yield(message) }
      }
    } catch {
      continuation.finish(throwing: error)
    }
  }
}
