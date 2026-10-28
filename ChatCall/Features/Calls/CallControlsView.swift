import SwiftUI

struct CallControlsView: View {
  let call: CallSnapshot
  let store: CallStore

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      VStack(spacing: 12) {
        HStack(spacing: 8) {
          control(
            "Microphone", symbol: call.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
            id: "microphone", value: call.microphoneEnabled ? "On" : "Off"
          ) {
            await store.toggleMicrophone()
          }
          control(
            "Camera", symbol: call.cameraEnabled ? "video.fill" : "video.slash.fill",
            id: "camera", value: call.cameraEnabled ? "On" : "Off"
          ) {
            await store.toggleCamera()
          }
          control(
            "Speaker", symbol: call.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
            id: "speaker", value: call.speakerEnabled ? "On" : "Off"
          ) {
            await store.toggleSpeaker()
          }
          control(
            "Flip camera", symbol: "arrow.triangle.2.circlepath.camera",
            id: "flip", value: call.cameraPosition == .front ? "Front" : "Back"
          ) {
            await store.flipCamera()
          }
        }
        Button("End call", systemImage: "phone.down.fill") { Task { await store.end() } }
          .frame(maxWidth: .infinity).buttonStyle(.glassProminent).tint(.red)
          .accessibilityIdentifier("call.end")
      }
      .padding(12)
      .glassEffect(in: .rect(cornerRadius: 28))
      .disabled(store.isBusy)
    }
  }

  private func control(
    _ label: String, symbol: String, id: String, value: String,
    action: @escaping @MainActor () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      Image(systemName: symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 48)
    }
    .buttonStyle(.glass)
    .accessibilityLabel(label)
    .accessibilityValue(value)
    .accessibilityIdentifier("call.\(id)")
  }
}
