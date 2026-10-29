import Foundation

/// Supplies a bearer token that is valid right now, refreshing it ahead of expiry.
nonisolated protocol AccessTokenProvider: Sendable {
  /// Throws `AuthError.invalidCredentials` when signed out or the session ended, `.revoked` when the
  /// server kicked it, and `.unavailable` when a refresh could not be attempted or reached the server.
  func validToken() async throws -> AccessToken
  /// Records that the server rejected `token`, so the next `validToken()` refreshes even if it looks fresh.
  func invalidate(_ token: AccessToken) async
}

/// A stable per-install id sent as `device_id` at sign-in; the server signs it into the token's `dev` claim.
nonisolated enum DeviceIdentifier {
  private static let key = "deviceIdentifier"

  static func current(defaults: UserDefaults = .standard) -> String {
    if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
    let fresh = "ios-\(UUID().uuidString.lowercased())"
    defaults.set(fresh, forKey: key)
    return fresh
  }
}
