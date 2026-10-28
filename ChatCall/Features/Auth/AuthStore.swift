import Foundation
import Observation

@MainActor
@Observable
final class AuthStore {
  enum State: Equatable {
    case unauthenticated
    case signingIn
    case authenticated(Session)
    case signingOut
    case failed(String)
  }

  private(set) var state: State = .unauthenticated
  var username = ""
  var password = ""
  /// Cancel feature tasks and replace tab routers here before Login becomes visible.
  var resetAuthenticatedState: @MainActor () -> Void = {}

  @ObservationIgnored private let client: any AuthClient
  @ObservationIgnored private var signInTask: Task<Session, any Error>?
  @ObservationIgnored private var revision = 0

  var canSignIn: Bool {
    switch state {
    case .unauthenticated, .failed: validationMessage == nil
    case .signingIn, .authenticated, .signingOut: false
    }
  }

  var validationMessage: String? {
    if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter your username or email."
    }
    if password.count < 6 { return "Use at least 6 characters for your password." }
    return nil
  }

  init(client: any AuthClient) { self.client = client }

  func signIn() async {
    guard canSignIn, !Task.isCancelled else { return }
    revision += 1
    let attempt = revision
    let credentials = Credentials(
      identity: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
    state = .signingIn
    let operation = Task { try await client.signIn(credentials: credentials) }
    signInTask = operation
    await withTaskCancellationHandler {
      do {
        let session = try await operation.value
        try Task.checkCancellation()
        guard attempt == revision else { return }
        password = ""
        state = .authenticated(session)
      } catch {
        guard attempt == revision else { return }
        if error is CancellationError || Task.isCancelled {
          state = .unauthenticated
        } else if error as? AuthError == .invalidCredentials {
          state = .failed("The username or password is incorrect. Try again.")
        } else {
          state = .failed("Unable to sign in. Please try again.")
        }
      }
    } onCancel: {
      operation.cancel()
    }
    if attempt == revision { signInTask = nil }
  }

  func signOut() async {
    guard state != .signingOut else { return }
    revision += 1
    signInTask?.cancel()
    signInTask = nil
    state = .signingOut
    username = ""
    password = ""
    resetAuthenticatedState()
    await client.signOut()
    state = .unauthenticated
  }
}
