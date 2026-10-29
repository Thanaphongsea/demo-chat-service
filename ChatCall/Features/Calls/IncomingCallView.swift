import SwiftUI

struct IncomingCallView: View {
  let call: CallSnapshot
  let store: CallStore

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      AvatarView(name: call.displayName, kind: call.kind == .group ? .group : .direct)
        .scaleEffect(1.5).padding(20)
      Text(call.displayName).font(.largeTitle.bold()).multilineTextAlignment(.center)
      Text(call.kind == .group ? "Incoming group video call" : "Incoming video call")
        .foregroundStyle(.secondary)
      if store.demoEnabled {
        Text("Simulated video and audio").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      GlassEffectContainer(spacing: 24) {
        HStack(spacing: 24) {
          Button("Decline", systemImage: "phone.down.fill") { Task { await store.decline() } }
            .tint(.red).buttonStyle(.glassProminent)
            .accessibilityIdentifier("call.decline")
          Button("Answer", systemImage: "video.fill") { Task { await store.answer() } }
            .tint(.green).buttonStyle(.glassProminent)
            .accessibilityIdentifier("call.answer")
        }
        .controlSize(.large).disabled(store.isBusy)
      }
    }
    .padding(24)
  }
}
