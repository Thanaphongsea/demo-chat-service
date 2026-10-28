import SwiftUI

struct NewConversationView: View {
  @Bindable var store: NewConversationStore
  let router: AppRouter
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack(path: stepPath) {
      MemberPickerView(store: store)
        .navigationDestination(for: NewConversationStore.Step.self) { _ in
          GroupDetailsView(store: store)
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              store.cancel()
              dismiss()
            }
            .accessibilityIdentifier("compose.cancel")
          }
        }
    }
    .safeAreaInset(edge: .bottom) {
      if store.isCreating {
        ProgressView("Creating chat…").padding().frame(maxWidth: .infinity)
          .background(.regularMaterial)
      } else if let failure = store.failure {
        Text(message(for: failure))
          .foregroundStyle(.red)
          .font(.callout)
          .padding()
          .frame(maxWidth: .infinity)
          .background(.regularMaterial)
          .accessibilityIdentifier("compose.error")
      }
    }
    .task { await store.load() }
    .onChange(of: store.createdConversation) { _, conversation in
      if let conversation {
        router.finishCompose(conversation, from: store)
        dismiss()
      }
    }
    .onDisappear { store.cancel() }
  }

  private var stepPath: Binding<[NewConversationStore.Step]> {
    Binding(
      get: { store.step == .groupDetails ? [.groupDetails] : [] },
      set: { store.step = $0.last ?? .members })
  }

  private func message(for failure: NewConversationStore.Failure) -> String {
    switch failure {
    case .chat(.groupNameRequired): "Enter a group name."
    case .chat(.invalidMembers): "Choose at least two people for a group."
    case .chat(.userNotFound): "A selected person is unavailable. Try again."
    case .chat, .unavailable: "Couldn’t create this chat. Please try again."
    }
  }
}

#Preview("Compose") {
  NewConversationView(
    store: NewConversationStore(client: MockChatClient(), currentUserID: MockSeed.currentUser.id),
    router: AppRouter(chatClient: MockChatClient()))
}

#Preview("Large text") {
  NewConversationView(
    store: NewConversationStore(client: MockChatClient(), currentUserID: MockSeed.currentUser.id),
    router: AppRouter(chatClient: MockChatClient())
  )
  .dynamicTypeSize(.accessibility3)
}
