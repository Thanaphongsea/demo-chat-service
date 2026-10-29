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
    if !systemActivatesAudio {
      session.lockForConfiguration()
      try? session.setActive(false)
      session.unlockForConfiguration()
    }
  }
}
