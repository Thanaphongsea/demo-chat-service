import SwiftUI

struct VideoTileView: View {
  let tile: VideoPage.Tile

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [.indigo, Color(red: 0.08, green: 0.12, blue: 0.24)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      VStack(spacing: 12) {
        Text(tile.user.initials).font(.largeTitle.bold())
          .frame(width: 72, height: 72).background(.white.opacity(0.15), in: Circle())
        if !tile.isVideoEnabled {
          Label("Camera off", systemImage: "video.slash.fill").font(.caption)
        }
        Text(tile.user.displayName).font(.headline).multilineTextAlignment(.center)
      }.padding(12)
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 24))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tile.user.displayName)
    .accessibilityValue(tile.isVideoEnabled ? "Simulated video" : "Camera off, audio only")
    .accessibilityIdentifier("call.tile.\(tile.user.id.rawValue)")
  }
}
