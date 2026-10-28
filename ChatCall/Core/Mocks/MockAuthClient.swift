import Foundation

actor MockAuthClient: AuthClient {
  private(set) var currentSession: Session?
  private let scheduler: any DemoScheduler
  private var revision = 0

  init(scheduler: any DemoScheduler = ImmediateDemoScheduler()) { self.scheduler = scheduler }
  func signIn(credentials: Credentials) async throws -> Session {
    let identity = credentials.identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identity.isEmpty, credentials.password.count >= 6,
      credentials != MockSeed.invalidCredentials
    else { throw AuthError.invalidCredentials }
    revision += 1
    let attempt = revision
    try await scheduler.sleep(for: .milliseconds(300))
    try Task.checkCancellation()
    guard attempt == revision else { throw CancellationError() }
    let session = Session(
      user: User(
        id: MockSeed.currentUser.id, displayName: identity,
        initials: String(identity.prefix(2)).uppercased()),
      signedInAt: MockSeed.date)
    currentSession = session
    return session
  }
  func signOut() async {
    revision += 1
    currentSession = nil
  }
}
