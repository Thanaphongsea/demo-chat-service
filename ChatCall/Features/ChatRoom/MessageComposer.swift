import SwiftUI

struct MessageComposer: View {
  @Binding var text: String
  let canSend: Bool
  var send: () -> Void

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        TextField("Message", text: $text)
          .font(.body)
          .submitLabel(.send)
          .onSubmit(send)
          .accessibilityLabel("Message")
          .accessibilityIdentifier("room.composer")
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .glassEffect(.regular.interactive(), in: .capsule)
        Button("Send message", systemImage: "arrow.up", action: send)
          .labelStyle(.iconOnly)
          .frame(minWidth: 44, minHeight: 44)
          .buttonStyle(.glassProminent)
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .disabled(!canSend)
          .accessibilityIdentifier("room.send")
      }
    }
  }
}
