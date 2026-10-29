#if DEBUG
  import SwiftUI

  // Static snapshots keep canvas rendering independent of event tasks and demo timers.
  private struct CallPreview: View {
    @State private var store: CallStore
    private let showsHistory: Bool

    init(state: CallState, kind: CallKind = .direct) {
      let store = Self.makeStore()
      store.receive(.callUpdated(Self.snapshot(state: state, kind: kind)))
      _store = State(initialValue: store)
      showsHistory = false
    }

    init(emptyHistory: Bool = false) {
      let store = Self.makeStore()
      if !emptyHistory {
        for (index, state) in [CallState.ended, .declined, .missed].enumerated() {
          store.receive(
            .callUpdated(
              Self.snapshot(state: state, kind: index == 1 ? .group : .direct, index: index)))
          store.dismiss()
        }
      }
      _store = State(initialValue: store)
      showsHistory = true
    }

    var body: some View {
      Group {
        if showsHistory {
          NavigationStack { CallsListView(store: store) }
        } else {
          CallPresentationView(store: store)
        }
      }
      .allowsHitTesting(false)
    }

    private static func makeStore() -> CallStore {
      CallStore(client: MockCallClient(), chatClient: MockChatClient())
    }

    private static func snapshot(
      state: CallState, kind: CallKind, index: Int = 0
    ) -> CallSnapshot {
      CallSnapshot(
        id: CallID("preview-call-\(index)"),
        conversationID: ConversationID(kind == .direct ? "conversation-ava" : "conversation-team"),
        kind: kind, direction: state == .ringing ? .outgoing : .incoming, state: state,
        participants: Array(MockSeed.standard.users.prefix(kind == .direct ? 2 : 6)),
        startedAt: MockSeed.date.addingTimeInterval(Double(index) * 60),
        microphoneEnabled: true, cameraEnabled: state != .reconnecting,
        speakerEnabled: true, cameraPosition: .front)
    }
  }

  #Preview("Incoming · direct") { CallPreview(state: .incoming) }
  #Preview("Incoming · group") { CallPreview(state: .incoming, kind: .group) }
  #Preview("Outgoing · ringing") { CallPreview(state: .ringing) }
  #Preview("Active · direct") { CallPreview(state: .active) }
  #Preview("Active · group with paging") { CallPreview(state: .active, kind: .group) }
  #Preview("Reconnecting · camera off") { CallPreview(state: .reconnecting, kind: .group) }
  #Preview("Ended") { CallPreview(state: .ended) }
  #Preview("Declined") { CallPreview(state: .declined) }
  #Preview("Missed") { CallPreview(state: .missed) }
  #Preview("Call history") { CallPreview() }
  #Preview("Call history · empty") { CallPreview(emptyHistory: true) }
  #Preview("Call history · dark") { CallPreview().preferredColorScheme(.dark) }
  #Preview("Incoming · accessibility text") {
    CallPreview(state: .incoming).dynamicTypeSize(.accessibility3)
  }
#endif
