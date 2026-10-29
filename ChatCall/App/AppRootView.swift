import SwiftUI

struct AppRootView: View {
  enum Gate {
    case launching
    case unauthenticated
    case authenticated
  }

  @State private var auth: AuthStore
  @State private var router: AppRouter
  private let sessionEnded: SessionEndedSignal

  var gate: Gate {
    switch auth.state {
    case .authenticated: .authenticated
    case .signingOut: .launching
    case .unauthenticated, .signingIn, .failed: .unauthenticated
    }
  }

  init(dependencies: AppDependencies = .mock()) {
    let auth = AuthStore(client: dependencies.auth)
    let router = AppRouter(
      chatClient: dependencies.chat, callClient: dependencies.calls, demoCalls: dependencies.demoCalls)
    let stop = dependencies.stopBackgroundWork
    auth.resetAuthenticatedState = { [weak router] in
      router?.reset()
      Task { await stop() }
    }
    sessionEnded = dependencies.sessionEnded
    _auth = State(initialValue: auth)
    _router = State(initialValue: router)
  }

  var body: some View {
    Group {
      switch gate {
      case .launching:
        ProgressView("Signing out…")
      case .unauthenticated:
        NavigationStack { LoginView(store: auth) }
      case .authenticated:
        AuthenticatedShellView(router: router)
      }
    }
    .environment(auth)
    .task {
      for await _ in sessionEnded.stream() { await auth.sessionEnded() }
    }
  }

}

#Preview {
  AppRootView()
}
