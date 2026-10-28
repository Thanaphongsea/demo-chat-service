import XCTest

nonisolated final class LoginFlowTests: XCTestCase {
  @MainActor
  func testDisabledLoginAndValidation() {
    let app = launch()
    let submit = app.buttons["auth.signIn"]
    XCTAssertTrue(submit.waitForExistence(timeout: 5))
    XCTAssertFalse(submit.isEnabled)
    app.textFields["auth.username"].tap()
    app.textFields["auth.username"].typeText("alex")
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText("12345")
    XCTAssertFalse(submit.isEnabled)
    XCTAssertTrue(app.staticTexts["Use at least 6 characters for your password."].exists)
    app.secureTextFields["auth.password"].typeText("6")
    XCTAssertTrue(submit.isEnabled)
  }

  @MainActor
  func testInvalidCredentialsShowError() {
    let app = launch()
    enterCredentials(app, username: "invalid", password: "invalid")
    app.buttons["auth.signIn"].tap()
    XCTAssertTrue(app.staticTexts["auth.error"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["auth.signIn"].isEnabled)
    XCTAssertFalse(app.buttons["auth.signOut"].exists)
  }

  @MainActor
  func testSecureEntryTogglePreservesPassword() {
    let app = launch()
    let password = app.secureTextFields["auth.password"]
    XCTAssertTrue(password.waitForExistence(timeout: 5))
    password.tap()
    password.typeText("123456")
    app.buttons["auth.togglePassword"].tap()
    XCTAssertEqual(app.textFields["auth.password"].value as? String, "123456")
    XCTAssertEqual(app.buttons["auth.togglePassword"].label, "Hide password")
    app.buttons["auth.togglePassword"].tap()
    XCTAssertTrue(app.secureTextFields["auth.password"].exists)
  }

  @MainActor
  func testSuccessfulLoginAndLogoutReturnsToEmptyLogin() {
    let app = launch()
    enterCredentials(app, username: "alex", password: "123456")
    app.buttons["auth.signIn"].tap()
    let logout = app.buttons["auth.signOut"]
    XCTAssertTrue(logout.waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["auth.username"].exists)
    logout.tap()
    XCTAssertTrue(app.textFields["auth.username"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields["auth.username"].value as? String, "Username or email")
    XCTAssertFalse(app.buttons["auth.signIn"].isEnabled)
  }

  @MainActor
  func testPasswordKeyboardSubmitSignsIn() {
    let app = launch()
    enterCredentials(app, username: "alex", password: "123456")
    app.secureTextFields["auth.password"].typeText("\n")
    XCTAssertTrue(app.buttons["auth.signOut"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-demo-immediateEvents"]
    app.launch()
    return app
  }

  @MainActor
  private func enterCredentials(_ app: XCUIApplication, username: String, password: String) {
    let identity = app.textFields["auth.username"]
    XCTAssertTrue(identity.waitForExistence(timeout: 5))
    identity.tap()
    identity.typeText(username)
    app.secureTextFields["auth.password"].tap()
    app.secureTextFields["auth.password"].typeText(password)
  }
}
