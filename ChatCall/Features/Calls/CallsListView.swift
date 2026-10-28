import SwiftUI

struct CallsListView: View {
  let store: CallStore

  var body: some View {
    List {
      Section {
        Text("Try a call with your demo contacts. Video and audio are simulated.")
          .foregroundStyle(.secondary)
        Button("Incoming direct call", systemImage: "person.crop.circle") {
          Task { await store.incoming(kind: .direct) }
        }
        .accessibilityIdentifier("calls.incoming.direct")
        Button("Incoming group call", systemImage: "person.3") {
          Task { await store.incoming(kind: .group) }
        }
        .accessibilityIdentifier("calls.incoming.group")
        Button("Simulate missed call", systemImage: "phone.down") {
          Task { await store.missed(kind: .direct) }
        }
        .accessibilityIdentifier("calls.missed")
      } header: {
        Text("Demo calls")
      }
      .disabled(store.isBusy)
      Section("Recent calls") {
        if store.history.isEmpty {
          ContentUnavailableView(
            "No calls yet", systemImage: "phone",
            description: Text("Your recent calls will appear here.")
          )
          .accessibilityIdentifier("calls.placeholder")
        } else {
          ForEach(store.history) { CallHistoryRow(call: $0) }
        }
      }
      if let error = store.errorMessage {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("call.error")
      }
    }
    .navigationTitle("Calls")
  }
}
