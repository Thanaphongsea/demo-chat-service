import AVFoundation
@preconcurrency import WebRTC

/// A peer connection with local capture, behind `MediaPeer`. Unified Plan, max-bundle; the server drives
/// every renegotiation, so this never creates an offer after the first.
nonisolated final class WebRTCPeer: NSObject, MediaPeer, RTCPeerConnectionDelegate, @unchecked Sendable {
  private static let factory: RTCPeerConnectionFactory = {
    RTCInitializeSSL()
    return RTCPeerConnectionFactory(
      encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
  }()

  private let userID: UserID
  private let lock = NSLock()
  private var connection: RTCPeerConnection?
  private var audioTrack: RTCAudioTrack?
  private var videoTrack: RTCVideoTrack?
  private var capturer: RTCCameraVideoCapturer?
  private var position: AVCaptureDevice.Position = .front
  private var cameraWanted = true
  private let candidates: AsyncStream<IceCandidate>.Continuation
  let localCandidates: AsyncStream<IceCandidate>

  /// The SFU names a stream by its user id; our own tracks go out in a stream with ours.
  init(userID: UserID) {
    self.userID = userID
    (localCandidates, candidates) = AsyncStream<IceCandidate>.makeStream()
    super.init()
  }

  // MARK: MediaPeer

  func start(iceServers: [WireICEServer], microphone: Bool, camera: Bool) async throws {
    let wantsMicrophone = microphone
    guard await MediaPermissions.requestMicrophone() else {
      throw MediaError.permissionDenied("microphone")
    }
    let cameraAllowed = camera ? await MediaPermissions.requestCamera() : false
    AudioSessionController.prepareForCall()

    let config = RTCConfiguration()
    config.sdpSemantics = .unifiedPlan
    config.bundlePolicy = .maxBundle
    config.rtcpMuxPolicy = .require
    config.continualGatheringPolicy = .gatherContinually
    config.iceServers = iceServers.map {
      RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
    }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
    else { throw MediaError.peerConnectionFailed }

    let audio = Self.factory.audioTrack(
      with: Self.factory.audioSource(with: constraints), trackId: "audio-\(userID.rawValue)")
    audio.isEnabled = wantsMicrophone
    connection.add(audio, streamIds: [userID.rawValue])

    let source = Self.factory.videoSource()
    let video = Self.factory.videoTrack(with: source, trackId: "video-\(userID.rawValue)")
    video.isEnabled = cameraAllowed
    connection.add(video, streamIds: [userID.rawValue])
    let capturer = RTCCameraVideoCapturer(delegate: source)

    lock.withLock {
      self.connection = connection
      self.audioTrack = audio
      self.videoTrack = video
      self.capturer = capturer
      self.cameraWanted = cameraAllowed
    }
    await MainActor.run { MediaRenderHub.shared.setLocal(video) }
    if cameraAllowed { try await startCapture(position: .front) }
  }

  func createOffer() async throws -> SessionDescription {
    let connection = try current()
    let offer = try await Self.offer(connection)
    try await Self.setLocal(connection, offer)
    return SessionDescription(type: "offer", sdp: offer.sdp)
  }

  func acceptAnswer(_ answer: SessionDescription) async throws {
    try await Self.setRemote(try current(), RTCSessionDescription(type: .answer, sdp: answer.sdp))
  }

  func acceptOffer(_ offer: SessionDescription) async throws -> SessionDescription {
    let connection = try current()
    try await Self.setRemote(connection, RTCSessionDescription(type: .offer, sdp: offer.sdp))
    let answer = try await Self.answer(connection)
    try await Self.setLocal(connection, answer)
    return SessionDescription(type: "answer", sdp: answer.sdp)
  }

  func addRemoteCandidate(_ candidate: IceCandidate) async throws {
    let connection = try current()
    let wire = RTCIceCandidate(
      sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.add(wire) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  func setMicrophone(_ enabled: Bool) async { lock.withLock { audioTrack }?.isEnabled = enabled }

  func setCamera(_ enabled: Bool) async {
    let video = lock.withLock { () -> RTCVideoTrack? in
      cameraWanted = enabled
      return videoTrack
    }
    video?.isEnabled = enabled
    if enabled {
      try? await startCapture(position: lock.withLock { position })
    } else {
      await stopCapture()
    }
  }

  func setSpeaker(_ enabled: Bool) async { AudioSessionController.setSpeaker(enabled) }

  func flipCamera() async {
    let next = lock.withLock { () -> AVCaptureDevice.Position in
      position = position == .front ? .back : .front
      return position
    }
    guard lock.withLock({ cameraWanted }) else { return }
    try? await startCapture(position: next)
  }

  func close() async {
    await stopCapture()
    let connection = lock.withLock { () -> RTCPeerConnection? in
      defer {
        self.connection = nil
        audioTrack = nil
        videoTrack = nil
      }
      return self.connection
    }
    connection?.close()
    candidates.finish()
    await MainActor.run { MediaRenderHub.shared.reset() }
    AudioSessionController.endCall()
  }

  // MARK: capture

  private func startCapture(position: AVCaptureDevice.Position) async throws {
    guard let capturer = lock.withLock({ capturer }) else { return }
    let devices = RTCCameraVideoCapturer.captureDevices()
    guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
      return  // no camera (a simulator): the call continues audio-only
    }
    let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
    // 1280x720 at up to 30 fps is the Android client's start point; not a validated iPhone target.
    let format = formats.min { lhs, rhs in
      Self.distance(lhs, from: (1280, 720)) < Self.distance(rhs, from: (1280, 720))
    }
    guard let format else { return }
    let fps = Int(min(30, format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      capturer.startCapture(with: device, format: format, fps: fps) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func stopCapture() async {
    guard let capturer = lock.withLock({ capturer }) else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      capturer.stopCapture { continuation.resume() }
    }
  }

  private static func distance(_ format: AVCaptureDevice.Format, from target: (Int32, Int32)) -> Int32 {
    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return abs(size.width - target.0) + abs(size.height - target.1)
  }

  // MARK: SDP helpers

  private func current() throws -> RTCPeerConnection {
    guard let connection = lock.withLock({ connection }) else { throw MediaError.peerConnectionFailed }
    return connection
  }

  private static func offer(_ connection: RTCPeerConnection) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { continuation in
      connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) {
        description, error in
        if let description { continuation.resume(returning: description) }
        else { continuation.resume(throwing: error ?? MediaError.invalidDescription) }
      }
    }
  }

  private static func answer(_ connection: RTCPeerConnection) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { continuation in
      connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) {
        description, error in
        if let description { continuation.resume(returning: description) }
        else { continuation.resume(throwing: error ?? MediaError.invalidDescription) }
      }
    }
  }

  private static func setLocal(_ connection: RTCPeerConnection, _ description: RTCSessionDescription)
    async throws
  {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.setLocalDescription(description) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private static func setRemote(_ connection: RTCPeerConnection, _ description: RTCSessionDescription)
    async throws
  {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.setRemoteDescription(description) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  // MARK: RTCPeerConnectionDelegate

  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    candidates.yield(
      IceCandidate(
        candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
  }

  /// The SFU keeps stream id equal to the user id, so the stream names whose video this is. Receivers can
  /// be reused for another user after renegotiation; that case needs real-device validation.
  func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]
  ) {
    guard let video = rtpReceiver.track as? RTCVideoTrack, let stream = streams.first else { return }
    let user = UserID(stream.streamId)
    Task { @MainActor in MediaRenderHub.shared.setRemote(video, for: user) }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
    guard let trackID = rtpReceiver.track?.trackId else { return }
    Task { @MainActor in MediaRenderHub.shared.removeRemote(trackID: trackID) }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
