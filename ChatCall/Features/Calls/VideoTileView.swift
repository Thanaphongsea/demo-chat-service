import SwiftUI
@preconcurrency import WebRTC

struct VideoTileView: View {
  let tile: VideoPage.Tile
  var isLocal = false
  /// True while calls are the mock: tiles then show a placeholder instead of live video.
  var simulated = true
  private let hub = MediaRenderHub.shared

  private var liveTrack: RTCVideoTrack? {
    guard !simulated, tile.isVideoEnabled else { return nil }
    return isLocal ? hub.localTrack : hub.remoteTracks[tile.user.id]
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [.indigo, Color(red: 0.08, green: 0.12, blue: 0.24)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      if let liveTrack {
        VideoTrackView(track: liveTrack, mirrored: isLocal)
        VStack {
          Spacer()
          Text(tile.user.displayName).font(.caption.bold()).padding(6)
            .background(.black.opacity(0.4), in: Capsule()).padding(8)
        }
      } else {
        VStack(spacing: 12) {
          Text(tile.user.initials).font(.largeTitle.bold())
            .frame(width: 72, height: 72).background(.white.opacity(0.15), in: Circle())
          if !tile.isVideoEnabled {
            Label("Camera off", systemImage: "video.slash.fill").font(.caption)
          }
          Text(tile.user.displayName).font(.headline).multilineTextAlignment(.center)
        }.padding(12)
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 24))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tile.user.displayName)
    .accessibilityValue(
      !tile.isVideoEnabled
        ? "Camera off, audio only" : (liveTrack != nil ? "Live video" : (simulated ? "Simulated video" : "Connecting video")))
    .accessibilityIdentifier("call.tile.\(tile.user.id.rawValue)")
  }
}
