import SwiftUI

struct GroupDetailsView: View {
  @Bindable var store: NewConversationStore

  var body: some View {
    Form {
      Section {
        TextField("Group name", text: $store.groupName)
          .textInputAutocapitalization(.words)
          .accessibilityLabel("Group name")
          .accessibilityIdentifier("compose.groupName")
          .disabled(store.isCreating)
      } header: {
        Text("Group name")
      } footer: {
        Text("Choose a name for your conversation.")
      }
      Section {
        ForEach(store.selectedUsers) { user in
          HStack(spacing: 12) {
            AvatarView(name: user.displayName, kind: .direct)
            Text(user.displayName)
          }
        }
      } header: {
        Text("\(store.selectedUsers.count) people, plus you")
      }
    }
    .navigationTitle("New group")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") { Task { await store.createGroup() } }
          .disabled(!store.canCreateGroup)
          .accessibilityIdentifier("compose.createGroup")
      }
    }
  }
}
