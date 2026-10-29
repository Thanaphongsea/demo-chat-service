import Foundation
import OSLog

/// Where the identity service lives. Defaults to the dev service; override with `-authBaseURL` / `-authAppID`.
nonisolated struct AuthConfiguration: Equatable, Sendable {
  let baseURL: URL
  let appID: String

  init(baseURL: URL, appID: String) {
    self.baseURL = baseURL
    self.appID = appID
  }

  /// Dev service. The quick tunnel URL changes when it is restarted; update it here or override at launch.
  static let dev = AuthConfiguration(
    baseURL: URL(string: "https://unset.invalid")!,
    appID: "1400000000")

  /// Launch-argument overrides on top of `dev`; an invalid override is ignored.
  init(defaults: UserDefaults = .standard) {
    let url = defaults.string(forKey: "authBaseURL").flatMap(URL.init(string:)).flatMap {
      $0.scheme == "https" || $0.scheme == "http" ? $0 : nil
    }
    let appID = defaults.string(forKey: "authAppID").flatMap { $0.isEmpty ? nil : $0 }
    self.init(
      baseURL: url ?? Self.dev.baseURL, appID: appID ?? Self.dev.appID)
  }
}

private nonisolated struct TokenRequest: Encodable {
  let userID: String
  let appID: String
  let password: String
  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case appID = "app_id"
    case password
  }
}

private nonisolated struct TokenResponse: Decodable {
  let token: String
  let expiresAt: String
  enum CodingKeys: String, CodingKey {
    case token
    case expiresAt = "expires_at"
  }
}

nonisolated let authLog = Logger(subsystem: "com.example.ChatCall", category: "auth")

actor LiveAuthClient: AuthClient {
  private let configuration: AuthConfiguration
  private let transport: any HTTPTransport
  private let store: any SessionStore
  private let now: @Sendable () -> Date
  private var session: Session?
  private var revision = 0

  init(
    configuration: AuthConfiguration, transport: any HTTPTransport = URLSession.shared,
    store: any SessionStore = KeychainSessionStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.transport = transport
    self.store = store
    self.now = now
  }

  var currentSession: Session? {
    if session == nil { session = store.load() }
    guard let current = session else { return nil }
    guard let expiry = current.accessToken?.expiresAt, expiry > now() else {
      session = nil
      store.clear()
      return nil
    }
    return current
  }

  func signIn(credentials: Credentials) async throws -> Session {
    let identity = credentials.identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identity.isEmpty, !credentials.password.isEmpty else {
      authLog.notice("signIn rejected locally: blank identity or password")
      throw AuthError.invalidCredentials
    }
    revision += 1
    let attempt = revision
    authLog.notice(
      "signIn #\(attempt) → POST \(self.requestSummary(user: identity), privacy: .public)")
    let started = ContinuousClock.now
    let (data, response) = try await post(identity: identity, password: credentials.password)
    let millis = Int(started.duration(to: .now) / .milliseconds(1))
    let requestID = response.value(forHTTPHeaderField: "X-Request-Id") ?? "-"
    authLog.notice(
      "signIn #\(attempt) ← HTTP \(response.statusCode) in \(millis)ms request-id=\(requestID, privacy: .public)"
    )
    try Task.checkCancellation()
    guard attempt == revision else {
      authLog.notice("signIn #\(attempt) discarded: superseded by sign-out or a newer attempt")
      throw CancellationError()
    }
    try Self.validate(status: response.statusCode, attempt: attempt)
    guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data),
      let expiresAt = Self.parseDate(body.expiresAt)
    else {
      authLog.error("signIn #\(attempt) failed: unreadable token response (\(data.count) bytes)")
      throw AuthError.invalidResponse
    }
    let userID = Self.subject(ofJWT: body.token) ?? identity
    let committed = Session(
      user: User(
        id: UserID(userID), displayName: identity, initials: String(identity.prefix(2)).uppercased()
      ),
      signedInAt: now(), accessToken: AccessToken(value: body.token, expiresAt: expiresAt))
    session = committed
    store.save(committed)
    let expiry = expiresAt.formatted(.iso8601)
    authLog.notice(
      "signIn #\(attempt) succeeded: user=\(userID, privacy: .public) token expires \(expiry, privacy: .public)"
    )
    return committed
  }

  private func requestSummary(user: String) -> String {
    "\(configuration.baseURL.absoluteString)/v1/token user_id=\(user) app_id=\(configuration.appID)"
  }

  private static func validate(status: Int, attempt: Int) throws {
    switch status {
    case 200: return
    case 401, 403:
      authLog.error("signIn #\(attempt) failed: invalid credentials")
      throw AuthError.invalidCredentials
    default:
      authLog.error("signIn #\(attempt) failed: unavailable (HTTP \(status))")
      throw AuthError.unavailable
    }
  }

  func signOut() async {
    authLog.notice("signOut: cleared local session")
    revision += 1
    session = nil
    store.clear()
  }

  private func post(identity: String, password: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: configuration.baseURL.appending(path: "v1/token"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      TokenRequest(userID: identity, appID: configuration.appID, password: password))
    do {
      return try await transport.send(request)
    } catch let error as URLError where error.code == .cancelled {
      authLog.notice("signIn request cancelled")
      throw CancellationError()
    } catch is CancellationError {
      authLog.notice("signIn request cancelled")
      throw CancellationError()
    } catch let error as AuthError {
      throw error
    } catch {
      authLog.error(
        "signIn transport error: \(error.localizedDescription, privacy: .public)")
      throw AuthError.unavailable
    }
  }

  private static func parseDate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
  }

  /// Reads the unverified `sub` claim for display identity only; the server owns validation.
  private static func subject(ofJWT token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let subject = claims["sub"] as? String, !subject.isEmpty
    else { return nil }
    return subject
  }
}
