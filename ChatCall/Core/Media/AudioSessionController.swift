import AVFoundation
@preconcurrency import WebRTC

/// Camera and microphone permission, requested only when a call needs it.
nonisolated enum MediaPermissions {
  static func requestMicrophone() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
    }
  }

  static func requestCamera() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .video)
  }
}

/// Owns the shared audio session for calls. WebRTC is told when the system has activated it, so the
/// same code serves CallKit (which activates the session) and a plain foreground call (which does not).
nonisolated enum AudioSessionController {
  /// Set once at launch when CallKit drives audio; foreground-only calls enable audio themselves.
  nonisolated(unsafe) static var systemActivatesAudio = false
  /// True once CallKit has activated the session for the current call.
  nonisolated(unsafe) private static var systemActivated = false
  /// How long to wait for CallKit before the app activates audio itself.
  nonisolated(unsafe) static var fallbackDelay: Duration = .seconds(2)

  static func prepareForCall() {
    let session = RTCAudioSession.sharedInstance()
    session.useManualAudio = true
    session.lockForConfiguration()
    defer { session.unlockForConfiguration() }
    try? session.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
    if !systemActivatesAudio {
      try? session.setActive(true)
      session.isAudioEnabled = true
    } else {
      systemActivated = false
      armFallback()
    }
  }

  /// CallKit normally activates the session, but if it never does (it refused the call, or it does not know
  /// this call) the call would be silent. After a short wait the app activates audio itself.
  private static func armFallback() {
    Task {
      try? await Task.sleep(for: fallbackDelay)
      guard !systemActivated else { return }
      let session = RTCAudioSession.sharedInstance()
      session.lockForConfiguration()
      defer { session.unlockForConfiguration() }
      try? session.setActive(true)
      session.isAudioEnabled = true
    }
  }

  static func setSpeaker(_ enabled: Bool) {
    let session = RTCAudioSession.sharedInstance()
    session.lockForConfiguration()
    defer { session.unlockForConfiguration() }
    try? session.overrideOutputAudioPort(enabled ? .speaker : .none)
  }

  /// CallKit has activated the audio session: let WebRTC start its audio unit.
  static func systemDidActivate(_ audioSession: AVAudioSession) {
    systemActivated = true
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidActivate(audioSession)
    session.isAudioEnabled = true
  }

  static func systemDidDeactivate(_ audioSession: AVAudioSession) {
    let session = RTCAudioSession.sharedInstance()
    session.isAudioEnabled = false
    session.audioSessionDidDeactivate(audioSession)
  }

  static func endCall() {
    let session = RTCAudioSession.sharedInstance()
    session.isAudioEnabled = false
    systemActivated = false
    if !systemActivatesAudio {
      session.lockForConfiguration()
      try? session.setActive(false)
      session.unlockForConfiguration()
    }
  }
}
