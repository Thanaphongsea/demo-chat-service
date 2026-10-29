import XCTest

nonisolated final class IntegrationQATests: XCTestCase {
  @MainActor
  func testFinalDemoScreenshotsAndLogout() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-demo-immediateEvents"]
    app.launch()
    XCTAssertTrue(app.textFields["auth.username"].waitForExistence(timeout: 5))
    capture("01-login", app: app)
    signIn(app)
    capture("02-chats", app: app)
    app.buttons["conversations.room.conversation-ava"].tap()
    XCTAssertTrue(app.staticTexts["Ready to catch up?"].waitForExistence(timeout: 5))
    capture("03-direct-room", app: app)
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
    app.buttons["call.end"].tap()
    app.buttons["call.done"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["conversations.room.conversation-team"].tap()
    XCTAssertTrue(app.staticTexts["Noah Williams"].waitForExistence(timeout: 5))
    capture("04-group-room", app: app)
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.otherElements["call.tile.user-noah"].waitForExistence(timeout: 5))
    capture("06-active-group-call", app: app)
    app.buttons["call.end"].tap()
    app.buttons["call.done"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["Calls"].tap()
    XCTAssertTrue(app.staticTexts["Ended"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["calls.incoming.direct"].tap()
    XCTAssertTrue(app.buttons["call.answer"].waitForExistence(timeout: 5))
    capture("05-incoming-call", app: app)
    app.buttons["call.decline"].tap()
    app.buttons["call.done"].tap()
    app.tabBars.buttons["Profile"].tap()
    app.buttons["auth.signOut"].tap()
    XCTAssertTrue(app.textFields["auth.username"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testDarkAccessibilityTextKeepsRoomAndCallControlsReachable() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-demo-immediateEvents", "-AppleInterfaceStyle", "Dark",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
    ]
    app.launch()
    signIn(app)
    let group = app.buttons["conversations.room.conversation-team"]
    for _ in 0..<4 where !group.isHittable { app.swipeUp() }
    XCTAssertTrue(group.waitForExistence(timeout: 5))
    group.tap()
    XCTAssertTrue(app.textFields["room.composer"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["room.composer"].isHittable)
    XCTAssertTrue(app.buttons["room.video"].isHittable)
    capture("qa-dark-accessibility-group-room", app: app)
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["call.end"].isHittable)
    XCTAssertTrue(app.buttons["call.microphone"].isHittable)
    capture("qa-dark-accessibility-group-call", app: app)
    app.buttons["call.end"].tap()
  }

  @MainActor
  private func signIn(_ app: XCUIApplication) {
    let username = app.textFields["auth.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    username.tap()
    username.typeText("alex")
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText("123456")
    let signIn = app.buttons["auth.signIn"]
    if !signIn.isHittable { app.swipeUp() }
    signIn.tap()
    XCTAssertTrue(app.buttons["conversations.room.conversation-ava"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func capture(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
