import XCTest

nonisolated final class MessagingFlowTests: XCTestCase {
  @MainActor
  func testIncomingGroupMessageIdentifiesItsSender() {
    let app = signedIn()
    app.buttons["conversations.room.conversation-team"].tap()
    XCTAssertTrue(app.staticTexts["See you on the call."].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Noah Williams"].exists, app.debugDescription)
    XCTAssertFalse(app.staticTexts["Group member"].exists)
  }

  @MainActor
  func testDirectSendDeliveryAndUpdatedPreview() {
    let app = signedIn()
    app.buttons["conversations.room.conversation-ava"].tap()
    let composer = app.textFields["room.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("A fresh direct message")
    app.buttons["room.send"].tap()
    XCTAssertTrue(app.staticTexts["A fresh direct message"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5), app.debugDescription)
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["A fresh direct message"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testGroupKeyboardSubmitAndWhitespaceValidation() {
    let app = signedIn()
    app.buttons["conversations.room.conversation-team"].tap()
    let composer = app.textFields["room.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["room.send"].isEnabled)
    composer.tap()
    composer.typeText("   ")
    XCTAssertFalse(app.buttons["room.send"].isEnabled)
    composer.typeText("Group hello\n")
    XCTAssertTrue(app.staticTexts["Group hello"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "Message")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Group hello"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testFailedSendRetriesWithoutDuplicateBubble() {
    let app = signedIn(arguments: ["-demo-failMessageSendOnce"])
    app.buttons["conversations.room.conversation-ava"].tap()
    let composer = app.textFields["room.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Retry this message")
    app.buttons["room.send"].tap()
    XCTAssertTrue(app.staticTexts["Failed to send"].waitForExistence(timeout: 5))
    app.buttons["Retry message"].tap()
    XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "label == %@", "Retry this message")).count, 1)
  }

  @MainActor
  func testRuntimeDeliveryProgressionAndVideoRouteHook() {
    let app = signedIn(immediate: false)
    app.buttons["conversations.room.conversation-ava"].tap()
    let composer = app.textFields["room.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Delivery progression")
    app.buttons["room.send"].tap()
    XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5))
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func signedIn(arguments: [String] = [], immediate: Bool = true) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = (immediate ? ["-demo-immediateEvents"] : ["-demo-mock"]) + arguments
    app.launch()
    let username = app.textFields["auth.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    username.tap()
    username.typeText("alex")
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText("123456")
    app.buttons["auth.signIn"].tap()
    XCTAssertTrue(app.buttons["conversations.room.conversation-ava"].waitForExistence(timeout: 5))
    return app
  }
}
