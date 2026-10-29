import XCTest

nonisolated final class SemanticAccessibilityTests: XCTestCase {
  @MainActor
  func testCriticalAccessibilitySurfaceTraversalAndActivation() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-demo-immediateEvents"]
    app.launch()

    var findings = verifyLoginAndSignIn(app)
    findings += createGroupAndExerciseCall(app)
    findings += exerciseDirectRoomAndCall(app)
    findings += exerciseIncomingCalls(app)
    findings += exerciseLogout(app)

    let auditAttachment = XCTAttachment(string: findings.joined(separator: "\n"))
    auditAttachment.name = "Accessibility audit findings"
    auditAttachment.lifetime = .keepAlways
    add(auditAttachment)
  }
}

extension SemanticAccessibilityTests {
  @MainActor
  private func verifyLoginAndSignIn(_ app: XCUIApplication) -> [String] {
    var findings: [String] = []
    let username = app.textFields["auth.username"]
    let password = app.secureTextFields["auth.password"]
    let passwordToggle = app.buttons["auth.togglePassword"]
    let signIn = app.buttons["auth.signIn"]
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    assertLabeledAndHittable([username, password, passwordToggle, signIn])
    assertTapTarget(passwordToggle)
    assertTopToBottom([username, password, signIn])
    findings += audit(app)
    username.tap()
    username.typeText("alex")
    password.tap()
    password.typeText("123456")
    passwordToggle.tap()
    let visiblePassword = app.textFields["auth.password"]
    XCTAssertEqual(visiblePassword.value as? String, "123456")
    XCTAssertEqual(passwordToggle.label, "Hide password")
    passwordToggle.tap()
    signIn.tap()

    let newChat = app.buttons["conversations.compose"]
    let directRow = app.buttons["conversations.room.conversation-ava"]
    XCTAssertTrue(directRow.waitForExistence(timeout: 5))
    assertLabeledAndHittable([newChat, directRow])
    findings += audit(app)
    return findings
  }

  @MainActor
  private func createGroupAndExerciseCall(_ app: XCUIApplication) -> [String] {
    var findings: [String] = []
    // Activate New chat, select members, and create a group through the exposed controls.
    app.buttons["conversations.compose"].tap()
    let ava = app.buttons["compose.member.user-ava"]
    let noah = app.buttons["compose.member.user-noah"]
    let next = app.buttons["compose.continue"]
    XCTAssertTrue(ava.waitForExistence(timeout: 5))
    assertLabeledAndHittable([ava, noah, next])
    findings += audit(app)
    ava.tap()
    noah.tap()
    next.tap()
    let groupName = app.textFields["compose.groupName"]
    let createGroup = app.buttons["compose.createGroup"]
    XCTAssertTrue(groupName.waitForExistence(timeout: 5))
    assertLabeledAndHittable([groupName, createGroup])
    findings += audit(app)
    groupName.tap()
    groupName.typeText("A11y crew")
    createGroup.tap()

    let composer = app.textFields["room.composer"]
    let send = app.buttons["room.send"]
    let video = app.buttons["room.video"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    assertLabeledAndHittable([video, composer])
    assertAbove(video, composer)
    findings += audit(app)
    sendMessage(app, composer: composer, send: send, text: "Accessible group message")
    video.tap()

    let microphone = app.buttons["call.microphone"]
    let camera = app.buttons["call.camera"]
    let speaker = app.buttons["call.speaker"]
    let flip = app.buttons["call.flip"]
    let reconnect = app.buttons["call.reconnect"]
    let end = app.buttons["call.end"]
    XCTAssertTrue(microphone.waitForExistence(timeout: 5))
    assertLabeledAndHittable([microphone, camera, speaker, flip, end])
    assertLabeledAndHittable([reconnect])
    assertTapTarget(reconnect)
    assertLeftToRight([microphone, camera, speaker, flip])
    findings += audit(app)
    for control in [microphone, camera, speaker, flip] { control.tap() }
    reconnect.tap()
    end.tap()
    XCTAssertTrue(app.buttons["call.done"].waitForExistence(timeout: 5))
    app.buttons["call.done"].tap()
    return findings
  }

  @MainActor
  private func sendMessage(
    _ app: XCUIApplication, composer: XCUIElement, send: XCUIElement, text: String
  ) {
    composer.tap()
    composer.typeText(text)
    XCTAssertTrue(send.isEnabled)
    assertLabeledAndHittable([send])
    send.tap()
    XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5))
  }

  @MainActor
  private func exerciseDirectRoomAndCall(_ app: XCUIApplication) -> [String] {
    var findings: [String] = []
    // Return to Chats and open a direct room; exercise its composer and video action too.
    let chatsTab = app.tabBars.buttons["Chats"]
    let directRow = app.buttons["conversations.room.conversation-ava"]
    let composer = app.textFields["room.composer"]
    let send = app.buttons["room.send"]
    let video = app.buttons["room.video"]
    let end = app.buttons["call.end"]
    XCTAssertTrue(chatsTab.waitForExistence(timeout: 5))
    chatsTab.tap()
    XCTAssertTrue(directRow.waitForExistence(timeout: 5))
    directRow.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    assertLabeledAndHittable([video, composer])
    assertAbove(video, composer)
    findings += audit(app)
    sendMessage(app, composer: composer, send: send, text: "Accessible direct message")
    video.tap()
    XCTAssertTrue(end.waitForExistence(timeout: 5))
    let controls = activeCallControls(app)
    assertLabeledAndHittable(controls)
    assertLeftToRight(Array(controls.prefix(4)))
    findings += audit(app)
    end.tap()
    XCTAssertTrue(app.buttons["call.done"].waitForExistence(timeout: 5))
    app.buttons["call.done"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    return findings
  }

  @MainActor
  private func exerciseIncomingCalls(_ app: XCUIApplication) -> [String] {
    var findings: [String] = []
    // Calls tab → incoming answer → active controls → end; then incoming decline.
    let end = app.buttons["call.end"]
    let callsTab = app.tabBars.buttons["Calls"]
    XCTAssertTrue(callsTab.waitForExistence(timeout: 5))
    callsTab.tap()
    let incoming = app.buttons["calls.incoming.direct"]
    XCTAssertTrue(incoming.waitForExistence(timeout: 5))
    incoming.tap()
    let decline = app.buttons["call.decline"]
    let answer = app.buttons["call.answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 5))
    assertLabeledAndHittable([decline, answer])
    assertLeftToRight([decline, answer])
    findings += audit(app)
    answer.tap()
    XCTAssertTrue(end.waitForExistence(timeout: 5))
    assertLabeledAndHittable(activeCallControls(app))
    findings += audit(app)
    end.tap()
    XCTAssertTrue(app.buttons["call.done"].waitForExistence(timeout: 5))
    app.buttons["call.done"].tap()

    XCTAssertTrue(incoming.waitForExistence(timeout: 5))
    incoming.tap()
    XCTAssertTrue(decline.waitForExistence(timeout: 5))
    assertLabeledAndHittable([decline, answer])
    decline.tap()
    XCTAssertTrue(app.buttons["call.done"].waitForExistence(timeout: 5))
    app.buttons["call.done"].tap()
    return findings
  }

  @MainActor
  private func activeCallControls(_ app: XCUIApplication) -> [XCUIElement] {
    [
      app.buttons["call.microphone"], app.buttons["call.camera"], app.buttons["call.speaker"],
      app.buttons["call.flip"], app.buttons["call.end"]
    ]
  }

  @MainActor
  private func exerciseLogout(_ app: XCUIApplication) -> [String] {
    var findings: [String] = []
    let profileTab = app.tabBars.buttons["Profile"]
    XCTAssertTrue(profileTab.waitForExistence(timeout: 5))
    profileTab.tap()
    let logout = app.buttons["auth.signOut"]
    XCTAssertTrue(logout.waitForExistence(timeout: 5))
    assertLabeledAndHittable([logout])
    findings += audit(app)
    logout.tap()
    XCTAssertTrue(app.textFields["auth.username"].waitForExistence(timeout: 5))
    return findings
  }

  @MainActor
  private func audit(_ app: XCUIApplication) -> [String] {
    var findings: [String] = []
    if #available(iOS 17.0, *) {
      do {
        try app.performAccessibilityAudit(for: .all) { issue in
          let element = issue.element?.identifier ?? "(none)"
          findings.append(
            "\(issue.auditType): \(issue.compactDescription); "
              + "\(issue.detailedDescription); element: \(element)")
          return true
        }
      } catch {
        findings.append("Accessibility audit errored: \(error.localizedDescription)")
      }
    }
    return findings
  }

  @MainActor
  private func assertLabeledAndHittable(
    _ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line
  ) {
    for element in elements {
      XCTAssertTrue(
        element.exists, "Missing accessibility element: \(element)", file: file, line: line)
      XCTAssertFalse(
        element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Empty accessibility label: \(element)", file: file, line: line)
      XCTAssertTrue(element.isHittable, "Not hittable: \(element)", file: file, line: line)
    }
  }

  @MainActor
  private func assertTopToBottom(
    _ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line
  ) {
    let tops = elements.map { $0.frame.minY }
    XCTAssertEqual(
      tops, tops.sorted(), "Expected top-to-bottom accessibility layout order", file: file,
      line: line)
  }

  @MainActor
  private func assertAbove(
    _ first: XCUIElement, _ second: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertLessThan(
      first.frame.midY, second.frame.midY, "Expected video action above composer", file: file,
      line: line)
  }

  @MainActor
  private func assertLeftToRight(
    _ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line
  ) {
    let lefts = elements.map { $0.frame.minX }
    XCTAssertEqual(
      lefts, lefts.sorted(), "Expected left-to-right accessibility layout order", file: file,
      line: line)
  }

  @MainActor
  private func assertTapTarget(
    _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertGreaterThanOrEqual(
      element.frame.width + 0.1, 48, "Tap target is too narrow", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      element.frame.height + 0.1, 48, "Tap target is too short", file: file, line: line)
  }
}
