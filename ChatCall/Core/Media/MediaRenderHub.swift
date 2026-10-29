import Observation
import SwiftUI
@preconcurrency import WebRTC

/// Where decoded video lands for the views: the local preview and one remote track per user.
/// A shared instance keeps `RTCVideoTrack` out of the domain types.
@MainActor
@Observable
final class MediaRenderHub {
  static let shared = MediaRenderHub()

  private(set) var localTrack: RTCVideoTrack?
  private(set) var remoteTracks: [UserID: RTCVideoTrack] = [:]

  func setLocal(_ track: RTCVideoTrack?) { localTrack = track }

  func setRemote(_ track: RTCVideoTrack?, for user: UserID) {
    if let track { remoteTracks[user] = track } else { remoteTracks.removeValue(forKey: user) }
  }

  func removeRemote(trackID: String) {
    remoteTracks = remoteTracks.filter { $0.value.trackId != trackID }
  }

  func reset() {
    localTrack = nil
    remoteTracks = [:]
  }
}

/// Renders one `RTCVideoTrack` with Metal and detaches the renderer when the view goes away, so a track
/// never keeps feeding frames to views that no longer exist.
struct VideoTrackView: UIViewRepresentable {
  let track: RTCVideoTrack
  var mirrored = false

  final class Coordinator {
    let track: RTCVideoTrack
    init(track: RTCVideoTrack) { self.track = track }
  }

  func makeCoordinator() -> Coordinator { Coordinator(track: track) }

  func makeUIView(context: Context) -> RTCMTLVideoView {
    let view = RTCMTLVideoView()
    view.videoContentMode = .scaleAspectFill
    view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    track.add(view)
    return view
  }

  func updateUIView(_ view: RTCMTLVideoView, context: Context) {}

  static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
    coordinator.track.remove(view)
  }
}
