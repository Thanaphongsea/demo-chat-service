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

/// Renders one `RTCVideoTrack` with Metal, detaching it when the view goes away.
struct VideoTrackView: UIViewRepresentable {
  let track: RTCVideoTrack
  var mirrored = false

  func makeUIView(context: Context) -> RTCMTLVideoView {
    let view = RTCMTLVideoView()
    view.videoContentMode = .scaleAspectFill
    view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    track.add(view)
    return view
  }

  func updateUIView(_ view: RTCMTLVideoView, context: Context) {}

  static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: ()) {}
}
