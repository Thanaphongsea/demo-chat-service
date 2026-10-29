/// What switching the camera needs. Turning it off only disables the track (the remote sees steady black
/// frames); the capture session is never stopped for that, because restarting it left the remote picture
/// frozen. Turning it on starts capture only if it is not already running.
nonisolated struct CameraPlan: Equatable, Sendable {
  let needsCapture: Bool

  static func make(enabled: Bool, isCapturing: Bool) -> CameraPlan {
    CameraPlan(needsCapture: enabled && !isCapturing)
  }
}
