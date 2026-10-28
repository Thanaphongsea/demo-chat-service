import SwiftUI

struct UnreadBadge: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Text(count > 99 ? "99+" : "\(count)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor, in: Capsule())
        .accessibilityLabel("\(count) unread messages")
    }
  }
}
