import XCTest

nonisolated final class LaunchTests: XCTestCase {
  @MainActor
  func testFreshLaunchShowsLoginScreen() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Login"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.tabBars.firstMatch.exists)
  }
}
