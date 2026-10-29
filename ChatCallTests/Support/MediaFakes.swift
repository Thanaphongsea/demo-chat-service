import Foundation

@testable import ChatCall

/// An ordered record shared by every fake in a test, so cross-object ordering can be asserted.
nonisolated final class Trace: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ item: String) { lock.withLock { items.append(item) } }
  var all: [String] { lock.withLock { items } }
}

nonisolated final class FakePeer: MediaPeer, @unchecked Sendable {
  let id: Int
  let trace: Trace
  private let lock = NSLock()
  private var candidateContinuation: AsyncStream<IceCandidate>.Continuation?
  private var gate: AsyncStream<Void>?
  var failStart = false
  var holdOffers = false
  private(set) var controls: [String] = []
  private(set) var closed = false
  let localCandidates: AsyncStream<IceCandidate>
  private let offerGate = AsyncStream<Void>.makeStream()

  init(id: Int, trace: Trace) {
    self.id = id
    self.trace = trace
    let (stream, continuation) = AsyncStream<IceCandidate>.makeStream()
    localCandidates = stream
    candidateContinuation = continuation
  }

  func start(iceServers: [WireICEServer], microphone: Bool, camera: Bool) async throws {
    trace.add("peer\(id).start(ice=\(iceServers.count),mic=\(microphone),cam=\(camera))")
    if failStart { throw URLError(.cannotConnectToHost) }
  }
  func createOffer() async throws -> SessionDescription {
    trace.add("peer\(id).createOffer")
    return SessionDescription(type: "offer", sdp: "offer-\(id)")
  }
  func acceptAnswer(_ answer: SessionDescription) async throws {
    trace.add("peer\(id).acceptAnswer(\(answer.sdp))")
  }
  func acceptOffer(_ offer: SessionDescription) async throws -> SessionDescription {
    trace.add("peer\(id).acceptOffer.begin(\(offer.sdp))")
    if holdOffers { for await _ in offerGate.stream { break } }
    trace.add("peer\(id).acceptOffer.end(\(offer.sdp))")
    return SessionDescription(type: "answer", sdp: "answer-to-\(offer.sdp)")
  }
  func addRemoteCandidate(_ candidate: IceCandidate) async throws {
    trace.add("peer\(id).remoteCandidate(\(candidate.candidate))")
  }
  func setMicrophone(_ enabled: Bool) async { lock.withLock { controls.append("mic=\(enabled)") } }
  func setCamera(_ enabled: Bool) async { lock.withLock { controls.append("cam=\(enabled)") } }
  func setSpeaker(_ enabled: Bool) async { lock.withLock { controls.append("speaker=\(enabled)") } }
  func flipCamera() async { lock.withLock { controls.append("flip") } }
  func close() async {
    lock.withLock { closed = true }
    trace.add("peer\(id).close")
    candidateContinuation?.finish()
  }

  func releaseOffer() { offerGate.continuation.yield() }
  func emitCandidate(_ text: String) {
    candidateContinuation?.yield(IceCandidate(candidate: text, sdpMid: "0", sdpMLineIndex: 0))
  }
}

nonisolated final class FakeTransport: SignalingTransport, @unchecked Sendable {
  let id: Int
  let trace: Trace
  private let lock = NSLock()
  private(set) var connectedURL: URL?
  private(set) var connectedToken: String?
  private(set) var sent: [SignalMessage] = []
  private(set) var closed = false
  var failConnect = false
  let messages: AsyncThrowingStream<SignalMessage, Error>
  private let continuation: AsyncThrowingStream<SignalMessage, Error>.Continuation

  init(id: Int, trace: Trace) {
    self.id = id
    self.trace = trace
    (messages, continuation) = AsyncThrowingStream<SignalMessage, Error>.makeStream()
  }

  func connect(url: URL, token: String) async throws {
    trace.add("socket\(id).connect")
    if failConnect { throw URLError(.cannotConnectToHost) }
    lock.withLock {
      connectedURL = url
      connectedToken = token
    }
  }
  func send(_ message: SignalMessage) async throws {
    lock.withLock { sent.append(message) }
    switch message {
    case .videoSubscriptions(let ids): trace.add("socket\(id).send(subs=\(ids.map { $0.joined(separator: ",") } ?? "all"))")
    case .offer(let d): trace.add("socket\(id).send(offer \(d.sdp))")
    case .answer(let d): trace.add("socket\(id).send(answer \(d.sdp))")
    case .ice(let c): trace.add("socket\(id).send(ice \(c.candidate))")
    default: trace.add("socket\(id).send(other)")
    }
  }
  func close() async {
    lock.withLock { closed = true }
    trace.add("socket\(id).close")
    continuation.finish()
  }

  func push(_ message: SignalMessage) { continuation.yield(message) }
  func drop() { continuation.finish(throwing: URLError(.networkConnectionLost)) }
  func finish() { continuation.finish() }
}

/// Builds peers and transports on demand and remembers every generation it created.
nonisolated final class MediaFactory: @unchecked Sendable {
  let trace = Trace()
  private let lock = NSLock()
  private(set) var peers: [FakePeer] = []
  private(set) var transports: [FakeTransport] = []
  var configurePeer: @Sendable (FakePeer) -> Void = { _ in }
  var configureTransport: @Sendable (FakeTransport) -> Void = { _ in }

  func makePeer() -> FakePeer {
    lock.withLock {
      let peer = FakePeer(id: peers.count + 1, trace: trace)
      configurePeer(peer)
      peers.append(peer)
      return peer
    }
  }
  func makeTransport() -> FakeTransport {
    lock.withLock {
      let transport = FakeTransport(id: transports.count + 1, trace: trace)
      configureTransport(transport)
      transports.append(transport)
      return transport
    }
  }
  var peer: FakePeer? { lock.withLock { peers.last } }
  var transport: FakeTransport? { lock.withLock { transports.last } }
  var generations: Int { lock.withLock { transports.count } }
}
