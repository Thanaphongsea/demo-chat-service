nonisolated protocol AuthClient: Sendable {
  var currentSession: Session? { get async }
  func signIn(credentials: Credentials) async throws -> Session
  func signOut() async
}
