import SwiftUI

struct MemberPickerView: View {
  @Bindable var store: NewConversationStore

  var body: some View {
    VStack(spacing: 0) {
      if !store.selectedUsers.isEmpty { selectedMembers }
      Group {
        switch store.state {
        case .loading:
          ProgressView("Loading people…")
        case .failed:
          ContentUnavailableView {
            Label("Couldn’t load people", systemImage: "wifi.exclamationmark")
          } description: {
            Text("Please try again.")
          } actions: {
            Button("Try again") { Task { await store.load() } }
              .accessibilityIdentifier("compose.retry")
          }
        case .loaded:
          if store.visibleUsers.isEmpty {
            ContentUnavailableView(
              store.users.isEmpty ? "No people available" : "No matching people",
              systemImage: "person.crop.circle.badge.questionmark")
          } else {
            List(store.visibleUsers) { user in memberRow(user) }
              .listStyle(.insetGrouped)
              .scrollContentBackground(.hidden)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(AppTheme.screenBackground)
    .searchable(
      text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Search people"
    )
    .navigationTitle("New chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(store.selectedUsers.count > 1 ? "Next" : "Open chat") {
          Task { await store.proceed() }
        }
        .disabled(!store.canContinue)
        .accessibilityIdentifier("compose.continue")
      }
    }
  }

  private var selectedMembers: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(store.selectedUsers) { user in
          Button {
            store.toggle(user)
          } label: {
            Label(user.displayName, systemImage: "xmark.circle.fill")
              .font(.subheadline)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .frame(minHeight: 44)
              .background(.quaternary, in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(store.isCreating)
          .accessibilityLabel("Remove \(user.displayName)")
          .accessibilityIdentifier("compose.remove.\(user.id.rawValue)")
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .accessibilityLabel("Selected people")
  }

  private func memberRow(_ user: User) -> some View {
    let selected = store.selectedUsers.contains { $0.id == user.id }
    return Button {
      store.toggle(user)
    } label: {
      HStack(spacing: 12) {
        AvatarView(name: user.displayName, kind: .direct)
        Text(user.displayName).foregroundStyle(.primary)
        Spacer(minLength: 8)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(store.isCreating)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(user.displayName)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .accessibilityIdentifier("compose.member.\(user.id.rawValue)")
  }
}
