import Foundation
import Security

nonisolated protocol SessionStore: Sendable {
  func load() -> Session?
  func save(_ session: Session)
  func clear()
}

nonisolated final class InMemorySessionStore: SessionStore, @unchecked Sendable {
  private let lock = NSLock()
  private var session: Session?
  func load() -> Session? { lock.withLock { session } }
  func save(_ session: Session) { lock.withLock { self.session = session } }
  func clear() { lock.withLock { session = nil } }
}

/// Keeps the live session in the Keychain, readable only on this device after first unlock.
nonisolated struct KeychainSessionStore: SessionStore {
  private struct Stored: Codable {
    let userID: String
    let displayName: String
    let initials: String
    let signedInAt: Date
    let token: String
    let expiresAt: Date
  }

  let service: String
  let account = "session"

  init(service: String = "com.example.ChatCall.auth") { self.service = service }

  func load() -> Session? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, let stored = try? JSONDecoder().decode(Stored.self, from: data)
    else { return nil }
    return Session(
      user: User(
        id: UserID(stored.userID), displayName: stored.displayName, initials: stored.initials),
      signedInAt: stored.signedInAt,
      accessToken: AccessToken(value: stored.token, expiresAt: stored.expiresAt))
  }

  func save(_ session: Session) {
    guard let token = session.accessToken else { return clear() }
    let stored = Stored(
      userID: session.user.id.rawValue, displayName: session.user.displayName,
      initials: session.user.initials, signedInAt: session.signedInAt, token: token.value,
      expiresAt: token.expiresAt)
    guard let data = try? JSONEncoder().encode(stored) else { return }
    clear()
    var item = baseQuery
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  func clear() { SecItemDelete(baseQuery as CFDictionary) }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
}
