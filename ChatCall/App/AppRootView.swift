import SwiftUI

struct AppRootView: View {
  enum Gate {
    case launching
    case unauthenticated
  }

  let gate: Gate = .unauthenticated

  var body: some View {
    NavigationStack {
      switch gate {
      case .launching:
        ProgressView("Starting ChatCall")
      case .unauthenticated:
        login
      }
    }
  }

  private var login: some View {
    VStack(spacing: AppTheme.contentSpacing) {
      Image(systemName: "bubble.left.and.bubble.right.fill")
        .font(.largeTitle)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      Text("ChatCall")
        .font(.largeTitle.bold())

      Text("Sign in to start a conversation.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(AppTheme.contentSpacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.screenBackground)
    .navigationTitle("Login")
    .accessibilityIdentifier("auth.login")
  }
}

#Preview {
  AppRootView()
}
