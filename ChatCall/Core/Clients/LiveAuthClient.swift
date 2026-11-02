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

  /// From `Config/Local.xcconfig` via Info.plist (`unset.invalid` if unset); `-authBaseURL` overrides it at launch.
  static let dev = AuthConfiguration(
    baseURL: BuildConfiguration.url(forInfoKey: "ChatCallAuthBaseURL"),
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
  let deviceID: String
  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case appID = "app_id"
    case password
    case deviceID = "device_id"
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

actor LiveAuthClient: AuthClient, AccessTokenProvider {
  /// Refresh this long before expiry so a slow refresh never races it.
  private static let refreshMargin: TimeInterval = 60

  private let configuration: AuthConfiguration
  private let transport: any HTTPTransport
  private let store: any SessionStore
  private let deviceID: String
  private let now: @Sendable () -> Date
  private var session: Session?
  private var revision = 0
  private var refreshTask: Task<AccessToken, Error>?
  private var rejectedToken: String?

  init(
    configuration: AuthConfiguration, transport: any HTTPTransport = URLSession.shared,
    store: any SessionStore = KeychainSessionStore(),
    deviceID: String = DeviceIdentifier.current(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.transport = transport
    self.store = store
    self.deviceID = deviceID
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
    refreshTask?.cancel()
    refreshTask = nil
    session = nil
    store.clear()
  }

  func validToken() async throws -> AccessToken {
    guard let token = currentSession?.accessToken else { throw AuthError.invalidCredentials }
    if let refreshTask { return try await refreshTask.value }
    let stale = token.expiresAt.timeIntervalSince(now()) <= Self.refreshMargin
    guard stale || token.value == rejectedToken else { return token }
    let epoch = revision
    let task = Task { try await self.refresh(token, epoch: epoch) }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }

  func invalidate(_ token: AccessToken) {
    rejectedToken = token.value
  }

  private func refresh(_ token: AccessToken, epoch: Int) async throws -> AccessToken {
    var request = URLRequest(url: configuration.baseURL.appending(path: "v1/token/refresh"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
    authLog.notice("refresh → POST /v1/token/refresh")
    let (data, response) = try await send(request)
    try Task.checkCancellation()
    guard epoch == revision else { throw CancellationError() }
    switch response.statusCode {
    case 200:
      guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data),
        let expiresAt = Self.parseDate(body.expiresAt), let current = session
      else { throw AuthError.invalidResponse }
      let renewed = AccessToken(value: body.token, expiresAt: expiresAt)
      let committed = Session(
        user: current.user, signedInAt: current.signedInAt, accessToken: renewed)
      session = committed
      rejectedToken = nil
      store.save(committed)
      authLog.notice("refresh succeeded")
      return renewed
    case 401:
      let code = Self.errorCode(in: data)
      authLog.error("refresh rejected: HTTP 401 code=\(code)")
      revision += 1
      session = nil
      rejectedToken = nil
      store.clear()
      throw code == 70009 ? AuthError.revoked : AuthError.invalidCredentials
    default:
      authLog.error("refresh failed: HTTP \(response.statusCode)")
      throw AuthError.unavailable
    }
  }

  /// The contract code is `ErrorCode` on the /v4 envelope and `code` on native /v1 answers.
  private static func errorCode(in data: Data) -> Int {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
    return (body["ErrorCode"] as? Int) ?? (body["code"] as? Int) ?? 0
  }

  private func post(identity: String, password: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: configuration.baseURL.appending(path: "v1/token"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      TokenRequest(
        userID: identity, appID: configuration.appID, password: password, deviceID: deviceID))
    return try await send(request)
  }

  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      return try await transport.send(request)
    } catch let error as URLError where error.code == .cancelled {
      authLog.notice("auth request cancelled")
      throw CancellationError()
    } catch is CancellationError {
      authLog.notice("auth request cancelled")
      throw CancellationError()
    } catch let error as AuthError {
      throw error
    } catch {
      authLog.error(
        "auth transport error: \(error.localizedDescription, privacy: .public)")
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
