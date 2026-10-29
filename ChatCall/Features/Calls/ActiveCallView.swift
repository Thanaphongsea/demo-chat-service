import SwiftUI

struct CallPresentationView: View {
  let store: CallStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let call = store.call {
        switch call.state {
        case .incoming: IncomingCallView(call: call, store: store)
        case .active, .reconnecting: ActiveCallView(call: call, store: store)
        case .ringing, .declined, .missed, .ended: OutgoingCallView(call: call, store: store)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.04, green: 0.06, blue: 0.10))
    .preferredColorScheme(.dark)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.call?.state)
    .interactiveDismissDisabled()
  }
}

struct ActiveCallView: View {
  let call: CallSnapshot
  @Bindable var store: CallStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 16) {
      VStack(spacing: 6) {
        Text(call.displayName).font(.headline)
        if call.state == .reconnecting {
          Label("Reconnecting…", systemImage: "wifi.exclamationmark")
            .foregroundStyle(.yellow).accessibilityIdentifier("call.reconnecting")
        } else {
          Text("Simulated video and audio").font(.caption).foregroundStyle(.secondary)
        }
      }
      GeometryReader { geometry in
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          ForEach(store.page.tiles) { tile in
            VideoTileView(tile: tile).frame(height: max(140, (geometry.size.height - 12) / 2))
          }
        }
      }
      if store.page.pageCount > 1 {
        HStack {
          Button("Previous", systemImage: "chevron.left") { store.page.previous() }
            .disabled(store.page.index == 0).accessibilityIdentifier("call.previous")
          Spacer()
          Text("Page \(store.page.index + 1) of \(store.page.pageCount)")
            .font(.caption).accessibilityIdentifier("call.page")
          Spacer()
          Button("Next", systemImage: "chevron.right") { store.page.next() }
            .disabled(store.page.index + 1 == store.page.pageCount).accessibilityIdentifier(
              "call.next")
        }.buttonStyle(.borderless)
      }
      Button("Simulate reconnect", systemImage: "wifi.exclamationmark") {
        Task { await store.reconnect() }
      }
      .font(.caption).frame(minHeight: 48).contentShape(Rectangle())
      .disabled(store.isBusy || call.state != .active)
      .accessibilityIdentifier("call.reconnect")
      CallControlsView(call: call, store: store)
    }
    .padding(16)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.page.index)
  }
}
