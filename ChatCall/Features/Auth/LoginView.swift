import SwiftUI

struct LoginView: View {
  let store: AuthStore

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.contentSpacing) {
        VStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.largeTitle)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
          Text("ChatCall").font(.largeTitle.bold())
          Text("Sign in to start a conversation.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        LoginForm(store: store)
        Text("Demo mode · Use any username and a password with at least 6 characters.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(AppTheme.contentSpacing)
      .frame(maxWidth: 480)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(AppTheme.screenBackground)
    .navigationTitle("Login")
    .accessibilityIdentifier("auth.login")
  }
}

#Preview("Default") {
  NavigationStack { LoginView(store: AuthStore(client: MockAuthClient())) }
}

#Preview("Filled") { LoginPreview(scenario: .filled) }
#Preview("Loading") { LoginPreview(scenario: .loading) }
#Preview("Error") { LoginPreview(scenario: .error) }
#Preview("Dark") { LoginPreview(scenario: .filled).preferredColorScheme(.dark) }
#Preview("Accessibility") {
  LoginPreview(scenario: .filled).environment(\.dynamicTypeSize, .accessibility3)
}

private struct LoginPreview: View {
  enum Scenario { case filled, loading, error }
  let scenario: Scenario
  @State private var store: AuthStore

  init(scenario: Scenario) {
    self.scenario = scenario
    let scheduler: any DemoScheduler =
      scenario == .loading ? ManualDemoScheduler() : ImmediateDemoScheduler()
    let store = AuthStore(client: MockAuthClient(scheduler: scheduler))
    store.username = scenario == .error ? "invalid" : "alex"
    store.password = scenario == .error ? "invalid" : "123456"
    _store = State(initialValue: store)
  }

  var body: some View {
    NavigationStack { LoginView(store: store) }
      .task {
        if scenario != .filled { await store.signIn() }
      }
  }
}
