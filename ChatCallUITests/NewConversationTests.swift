import XCTest

nonisolated final class NewConversationTests: XCTestCase {
  @MainActor
  func testCreateDirectAndReopenExistingDirect() {
    let app = signedIn()
    compose(app)
    app.buttons["compose.member.user-noah"].tap()
    app.buttons["compose.continue"].tap()
    XCTAssertTrue(app.textFields["room.composer"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Noah Williams"].exists)
    app.navigationBars.buttons.firstMatch.tap()
    compose(app)
    app.buttons["compose.member.user-ava"].tap()
    app.buttons["compose.continue"].tap()
    XCTAssertTrue(app.textFields["room.composer"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Ava Chen"].exists)
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertEqual(app.buttons.matching(identifier: "conversations.room.conversation-ava").count, 1)
  }

  @MainActor
  func testCreateNamedGroupAndOpenIt() {
    let app = signedIn()
    compose(app)
    XCTAssertFalse(app.buttons["compose.continue"].isEnabled)
    app.buttons["compose.member.user-ava"].tap()
    app.buttons["compose.member.user-noah"].tap()
    XCTAssertTrue(app.buttons["compose.remove.user-ava"].exists)
    app.buttons["compose.continue"].tap()
    let name = app.textFields["compose.groupName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["compose.createGroup"].isEnabled)
    name.tap()
    name.typeText("Weekend crew")
    app.buttons["compose.createGroup"].tap()
    XCTAssertTrue(app.textFields["room.composer"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Weekend crew"].exists)
    XCTAssertFalse(app.buttons["compose.cancel"].exists)
  }

  @MainActor
  func testSearchSelectionRemovalAndCancel() {
    let app = signedIn()
    compose(app)
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Ava")
    app.buttons["compose.member.user-ava"].tap()
    XCTAssertFalse(app.buttons["compose.member.user-noah"].exists)
    app.buttons["compose.remove.user-ava"].tap()
    app.buttons["Close"].tap()
    XCTAssertFalse(app.buttons["compose.continue"].isEnabled)
    app.buttons["compose.cancel"].tap()
    compose(app)
    XCTAssertFalse(app.buttons["compose.continue"].isEnabled)
    XCTAssertTrue(app.buttons["compose.member.user-noah"].exists)
  }

  @MainActor
  private func compose(_ app: XCUIApplication) {
    let button = app.buttons["conversations.compose"]
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    XCTAssertTrue(
      app.buttons["compose.member.user-ava"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  private func signedIn() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-demo-immediateEvents"]
    app.launch()
    let username = app.textFields["auth.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    username.tap()
    username.typeText("alex")
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText("123456")
    app.buttons["auth.signIn"].tap()
    return app
  }
}
