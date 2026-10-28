import SwiftUI

struct AppRootView: View {
  enum Gate {
    case launching
    case unauthenticated
    case authenticated
  }

  @State private var auth: AuthStore

  var gate: Gate {
    switch auth.state {
    case .authenticated: .authenticated
    case .signingOut: .launching
    case .unauthenticated, .signingIn, .failed: .unauthenticated
    }
  }

  init(dependencies: AppDependencies = .mock()) {
    _auth = State(initialValue: AuthStore(client: dependencies.auth))
  }

  var body: some View {
    NavigationStack {
      switch gate {
      case .launching:
        ProgressView("Signing out…")
      case .unauthenticated:
        LoginView(store: auth)
      case .authenticated:
        authenticatedPlaceholder
      }
    }
    .environment(auth)
  }

  private var authenticatedPlaceholder: some View {
    VStack(spacing: AppTheme.contentSpacing) {
      if case .authenticated(let session) = auth.state {
        Text("Welcome, \(session.user.displayName)")
          .font(.title2.bold())
          .multilineTextAlignment(.center)
      }
      Text("You’re signed in.").foregroundStyle(.secondary)
      Button("Sign out") { Task { await auth.signOut() } }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("auth.signOut")
    }
    .padding(AppTheme.contentSpacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.screenBackground)
    .navigationTitle("Chats")
  }
}

#Preview {
  AppRootView()
}
