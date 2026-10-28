import SwiftUI

struct AvatarView: View {
  let name: String
  let kind: ConversationKind
  @ScaledMetric(relativeTo: .body) private var size = 48

  private var initials: String {
    name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
  }

  var body: some View {
    ZStack {
      Circle().fill(Color.accentColor.opacity(0.12))
      if kind == .group {
        Image(systemName: "person.3.fill").font(.body.weight(.semibold))
      } else {
        Text(initials).font(.body.weight(.semibold))
      }
    }
    .foregroundStyle(Color.accentColor)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
