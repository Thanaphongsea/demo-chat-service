import XCTest

/// Opt-in: drives the real app against the dev services. u_alice rings u_bob over REST; the app, signed in as
/// u_bob, must show the incoming call, answer it, and stay in the call. Needs
/// `TEST_RUNNER_CHATCALL_LIVE_PASSWORD`, `TEST_RUNNER_CHATCALL_AUTH_URL` and
/// `TEST_RUNNER_CHATCALL_VOIP_URL`. It places a real call on the dev VoIP service.
nonisolated final class LiveCallFlowTests: XCTestCase {
  private static let auth = ProcessInfo.processInfo.environment["CHATCALL_AUTH_URL"] ?? ""
  private static let voip = ProcessInfo.processInfo.environment["CHATCALL_VOIP_URL"] ?? ""

  @MainActor
  func testBobAnswersAnIncomingCall() throws {
    let password = try XCTUnwrap(
      ProcessInfo.processInfo.environment["CHATCALL_LIVE_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 },
      "set TEST_RUNNER_CHATCALL_LIVE_PASSWORD")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let username = app.textFields["auth.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    username.tap()
    username.typeText("u_bob")
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText(password)
    app.buttons["auth.signIn"].tap()
    XCTAssertTrue(app.tabBars.buttons["Calls"].waitForExistence(timeout: 20), "signed-in shell did not appear")
    sleep(3)  // let the call client start polling

    let callID = try Self.aliceCallsBob(password: password)
    attach(app, "1-before-answer")
    let answer = app.buttons["call.answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 20), "incoming call screen never appeared (call \(callID))")
    attach(app, "2-incoming")
    answer.tap()

    let end = app.buttons["call.end"]
    XCTAssertTrue(end.waitForExistence(timeout: 15), "no active call screen after answering")
    attach(app, "3-after-answer")
    for second in 1...12 {
      sleep(1)
      XCTAssertTrue(end.exists, "the call screen disappeared after \(second)s")
      XCTAssertFalse(app.staticTexts["call.error"].exists, "an error appeared after \(second)s")
    }
    attach(app, "4-12s-later")
    end.tap()
  }

  // MARK: REST helpers (alice)

  private static func aliceCallsBob(password: String) throws -> String {
    let token = try request("\(auth)/v1/token", token: nil, body: [
      "user_id": "u_alice", "app_id": "1400000000", "password": password, "device_id": "ios-ui-alice"
    ])["token"] as? String
    let created = try request("\(voip)/api/calls", token: try XCTUnwrap(token), body: [
      "caller_id": "u_alice", "caller_name": "u_alice", "callee_id": "u_bob",
      "room_id": "dm_u_alice_u_bob", "idempotency_key": "ui-\(UUID().uuidString)"
    ])
    return try XCTUnwrap(created["call_id"] as? String)
  }

  private static func request(_ url: String, token: String?, body: [String: Any]) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    nonisolated(unsafe) var result: [String: Any] = [:]
    nonisolated(unsafe) var failure: String?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
      defer { done.signal() }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard let data, (200..<300).contains(status),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else {
        failure = "HTTP \(status) \(error?.localizedDescription ?? "")"
        return
      }
      result = object
    }.resume()
    done.wait()
    if let failure { throw NSError(domain: "LiveCallFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
    return result
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
