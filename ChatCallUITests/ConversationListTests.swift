import XCTest

nonisolated final class ConversationListTests: XCTestCase {
  @MainActor
  func testTabsBadgesSearchAndRoomNavigation() {
    let app = signedIn()
    XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.tabBars.buttons["Calls"].exists)
    XCTAssertTrue(app.tabBars.buttons["Profile"].exists)
    XCTAssertTrue(app.staticTexts["Direct"].exists)
    XCTAssertTrue(app.staticTexts["Group"].exists)
    XCTAssertTrue(app.staticTexts["conversations.unread.conversation-ava"].exists)
    XCTAssertEqual(
      app.staticTexts["conversations.unread.conversation-ava"].label, "1 unread messages")
    XCTAssertEqual(
      app.staticTexts["conversations.unread.conversation-team"].label, "2 unread messages")
    let search = app.searchFields.firstMatch
    if !search.exists { app.swipeDown() }
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("call")
    XCTAssertTrue(app.buttons["conversations.room.conversation-team"].exists)
    XCTAssertFalse(app.buttons["conversations.room.conversation-ava"].exists)
    app.buttons["conversations.room.conversation-team"].tap()
    XCTAssertTrue(app.staticTexts["room.placeholder"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Design Team"].exists)
    app.tabBars.buttons["Calls"].tap()
    XCTAssertTrue(app.staticTexts["calls.placeholder"].exists)
    app.tabBars.buttons["Chats"].tap()
    XCTAssertTrue(app.staticTexts["room.placeholder"].exists)
    app.tabBars.buttons["Profile"].tap()
    XCTAssertTrue(app.buttons["auth.signOut"].exists)
  }

  @MainActor
  func testEmptyFixtureAndSearchNoResults() {
    let empty = signedIn(arguments: ["-demo-emptyConversations"])
    XCTAssertTrue(empty.staticTexts["conversations.empty"].waitForExistence(timeout: 5))
    empty.terminate()
    let app = signedIn()
    let search = app.searchFields.firstMatch
    if !search.exists { app.swipeDown() }
    search.tap()
    search.typeText("unmatched query")
    XCTAssertTrue(app.staticTexts["conversations.noResults"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testFailedFixtureRetriesToConversations() {
    let app = signedIn(arguments: ["-demo-failConversationLoadOnce"])
    XCTAssertTrue(app.staticTexts["conversations.error"].waitForExistence(timeout: 5))
    app.buttons["conversations.retry"].tap()
    XCTAssertTrue(app.buttons["conversations.room.conversation-ava"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testLogoutFromRoomResetsTabNavigationAndSearch() {
    let app = signedIn()
    app.buttons["conversations.room.conversation-ava"].tap()
    XCTAssertTrue(app.staticTexts["room.placeholder"].waitForExistence(timeout: 5))
    app.tabBars.buttons["Profile"].tap()
    app.buttons["auth.signOut"].tap()
    signIn(app)
    XCTAssertTrue(app.buttons["conversations.room.conversation-ava"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["room.placeholder"].exists)
    XCTAssertTrue(app.tabBars.buttons["Chats"].isSelected)
  }

  @MainActor
  private func signedIn(arguments: [String] = []) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-demo-immediateEvents"] + arguments
    app.launch()
    signIn(app)
    return app
  }

  @MainActor
  private func signIn(_ app: XCUIApplication) {
    let username = app.textFields["auth.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    username.tap()
    username.typeText("alex")
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText("123456")
    app.buttons["auth.signIn"].tap()
  }
}
