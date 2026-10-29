import SwiftUI

struct OutgoingCallView: View {
  let call: CallSnapshot
  let store: CallStore

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      AvatarView(name: call.displayName, kind: call.kind == .group ? .group : .direct)
      Text(call.displayName).font(.title.bold()).multilineTextAlignment(.center)
      Text(status).font(.title2).accessibilityIdentifier("call.status")
      if store.demoEnabled {
        Text("Simulated video and audio").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if call.state.isTerminal {
        Button("Done") { store.dismiss() }.buttonStyle(.glassProminent).controlSize(.large)
          .accessibilityIdentifier("call.done")
      } else {
        CallControlsView(call: call, store: store)
      }
    }
    .padding(24)
  }

  private var status: String {
    switch call.state {
    case .declined: "Call declined"
    case .missed: "Missed call"
    case .ended: "Call ended"
    default: "Calling…"
    }
  }
}
