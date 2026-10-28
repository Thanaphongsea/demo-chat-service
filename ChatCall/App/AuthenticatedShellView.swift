import SwiftUI

struct AuthenticatedShellView: View {
  @Bindable var router: AppRouter
  @Environment(AuthStore.self) private var auth

  var body: some View {
    TabView(selection: $router.selectedTab) {
      Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: .chats) {
        TabNavigationView(path: router.chats, router: router) {
          ConversationListView(store: router.conversations) {
            if case .authenticated(let session) = auth.state {
              router.presentComposer(currentUserID: session.user.id)
            }
          }
          .toolbar { ToolbarItem(placement: .topBarTrailing) { signOutButton } }
        }
      }
      .badge(router.conversations.totalUnreadCount)
      Tab("Calls", systemImage: "phone", value: .calls) {
        TabNavigationView(path: router.calls, router: router) {
          ContentUnavailableView(
            "No calls yet", systemImage: "phone",
            description: Text("Your recent calls will appear here.")
          )
          .accessibilityIdentifier("calls.placeholder")
          .navigationTitle("Calls")
        }
      }
      Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
        TabNavigationView(path: router.profile, router: router) {
          VStack(spacing: AppTheme.contentSpacing) {
            if case .authenticated(let session) = auth.state {
              AvatarView(name: session.user.displayName, kind: .direct)
              Text(session.user.displayName).font(.title2.bold())
            }
            signOutButton.buttonStyle(.bordered).controlSize(.large)
          }
          .padding(AppTheme.contentSpacing)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(AppTheme.screenBackground)
          .navigationTitle("Profile")
        }
      }
    }
    .sheet(item: $router.presentedSheet) { sheet in
      switch sheet {
      case .newConversation(let store): NewConversationView(store: store, router: router)
      }
    }
  }

  private var signOutButton: some View {
    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
      Task { await auth.signOut() }
    }
    .accessibilityIdentifier("auth.signOut")
  }
}

private struct TabNavigationView<Content: View>: View {
  @Bindable var path: RouterPath
  let router: AppRouter
  @ViewBuilder let content: () -> Content

  var body: some View {
    NavigationStack(path: $path.routes) {
      content()
        .navigationDestination(for: AppRoute.self) { route in
          AppDestinationView(route: route, router: router)
        }
    }
  }
}

/// Central mapping keeps route values stable while later tasks fill in destination behavior.
private struct AppDestinationView: View {
  let route: AppRoute
  let router: AppRouter

  var body: some View {
    switch route {
    case .room(let id):
      ContentUnavailableView(
        "Conversation", systemImage: "bubble.left.and.bubble.right",
        description: Text("Messages will appear here.")
      )
      .accessibilityIdentifier("room.placeholder")
      .navigationTitle(router.conversations.conversations.first { $0.id == id }?.name ?? "Chat")
    case .call:
      ContentUnavailableView("Call", systemImage: "phone")
    case .compose:
      ContentUnavailableView("New chat", systemImage: "square.and.pencil")
    case .profile:
      ContentUnavailableView("Profile", systemImage: "person.crop.circle")
    }
  }
}
