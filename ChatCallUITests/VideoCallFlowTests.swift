import XCTest

nonisolated final class VideoCallFlowTests: XCTestCase {
  @MainActor
  func testOutgoingDirectControlsAndEnd() {
    let app = signedIn()
    app.buttons["conversations.room.conversation-ava"].tap()
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.buttons["call.microphone"].waitForExistence(timeout: 5))
    for control in ["microphone", "camera", "speaker"] {
      app.buttons["call.\(control)"].tap()
      XCTAssertEqual(app.buttons["call.\(control)"].value as? String, "Off")
    }
    app.buttons["call.flip"].tap()
    XCTAssertEqual(app.buttons["call.flip"].value as? String, "Back")
    app.buttons["call.end"].tap()
    XCTAssertTrue(app.staticTexts["Call ended"].waitForExistence(timeout: 5))
    app.buttons["call.done"].tap()
    XCTAssertTrue(app.buttons["room.video"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testOutgoingGroupCallsEveryoneWithoutPicker() {
    let app = signedIn()
    app.buttons["conversations.room.conversation-team"].tap()
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.otherElements["call.tile.user-me"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.otherElements["call.tile.user-ava"].exists)
    XCTAssertTrue(app.otherElements["call.tile.user-noah"].exists)
    XCTAssertFalse(app.navigationBars["Select members"].exists)
    app.buttons["call.end"].tap()
  }

  @MainActor
  func testIncomingAnswerReconnectDeclineAndMissed() {
    let app = signedIn()
    app.tabBars.buttons["Calls"].tap()
    app.buttons["calls.incoming.direct"].tap()
    XCTAssertTrue(app.buttons["call.answer"].waitForExistence(timeout: 5))
    app.buttons["call.answer"].tap()
    app.buttons["call.reconnect"].tap()
    XCTAssertTrue(app.staticTexts["Reconnecting…"].waitForExistence(timeout: 3))
    app.buttons["call.end"].tap()
    app.buttons["call.done"].tap()
    app.buttons["calls.incoming.group"].tap()
    XCTAssertTrue(app.buttons["call.decline"].waitForExistence(timeout: 5))
    app.buttons["call.decline"].tap()
    XCTAssertTrue(app.staticTexts["Call declined"].waitForExistence(timeout: 5))
    app.buttons["call.done"].tap()
    app.buttons["calls.missed"].tap()
    XCTAssertTrue(app.staticTexts["Missed"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testCreatedGroupPagesKeepLocalTile() {
    let app = signedIn()
    app.buttons["conversations.compose"].tap()
    for id in ["user-ava", "user-noah", "user-1", "user-10"] {
      let member = app.buttons["compose.member.\(id)"]
      for _ in 0..<3 where !member.exists { app.swipeUp() }
      XCTAssertTrue(member.waitForExistence(timeout: 5))
      member.tap()
    }
    app.buttons["compose.continue"].tap()
    let name = app.textFields["compose.groupName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("Paging team")
    app.buttons["compose.createGroup"].tap()
    XCTAssertTrue(app.buttons["room.video"].waitForExistence(timeout: 5))
    app.buttons["room.video"].tap()
    XCTAssertTrue(app.buttons["call.next"].waitForExistence(timeout: 5))
    app.buttons["call.next"].tap()
    XCTAssertEqual(app.staticTexts["call.page"].label, "Page 2 of 2")
    XCTAssertTrue(app.otherElements["call.tile.user-me"].exists)
    XCTAssertTrue(app.otherElements["call.tile.user-10"].exists)
    XCTAssertFalse(app.buttons["call.next"].isEnabled)
    app.buttons["call.previous"].tap()
    XCTAssertEqual(app.staticTexts["call.page"].label, "Page 1 of 2")
    XCTAssertTrue(app.otherElements["call.tile.user-me"].exists)
    app.buttons["call.end"].tap()
  }

  @MainActor
  private func signedIn() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-demo-mock"]  // the default launch signs in against the live service
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
