import Testing

@testable import ChatCall

struct VideoPageTests {
  // Losing the terminal outcome makes completed calls look like uncompleted attempts.
  @Test("Ended history retains its outcome for incoming and outgoing calls")
  func endedHistoryOutcome() {
    for direction in [CallDirection.incoming, .outgoing] {
      let call = CallSnapshot(
        id: CallID("finished"), conversationID: ConversationID("conversation-ava"),
        kind: .direct, direction: direction, state: .ended,
        participants: Array(MockSeed.standard.users.prefix(2)), startedAt: MockSeed.date,
        microphoneEnabled: true, cameraEnabled: true, speakerEnabled: true,
        cameraPosition: .front)
      #expect(call.historyStatus == "Ended")
    }
  }

  // Dropping the local tile or slicing by four remotes breaks every page.
  @Test("Every page keeps local plus at most three remote people, including audio-only tiles")
  func pages() {
    var page = VideoPage(localUser: MockSeed.currentUser)
    page.update(
      participants: Array(MockSeed.standard.users.prefix(8)), audioOnlyIDs: [UserID("user-ava")])
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-ava", "user-noah", "user-1"])
    #expect(page.tiles.first { $0.id == UserID("user-ava") }?.isVideoEnabled == false)
    #expect(page.pageCount == 3)
    page.next()
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-2", "user-3", "user-4"])
    page.next()
    page.next()
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-5"])
    page.previous()
    #expect(page.index == 1)
  }

  // Resorting incoming snapshots would move tiles; failing to clamp yields a blank page.
  @Test("Reordered snapshots preserve ordering; departures clamp the page and newcomers append")
  func rosterChanges() {
    var page = VideoPage(localUser: MockSeed.currentUser)
    let users = Array(MockSeed.standard.users.prefix(8))
    page.update(participants: users)
    page.next()
    page.next()
    page.update(participants: Array(users.reversed()))
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-5"])
    page.update(participants: Array(users.prefix(3)), audioOnlyIDs: [UserID("user-me")])
    #expect(page.index == 0)
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-ava", "user-noah"])
    #expect(page.tiles.first?.isVideoEnabled == false)
    page.update(participants: [users[3], users[2], users[0]])
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-noah", "user-1"])
    page.previous()
    #expect(page.index == 0)
  }

  @Test("Sixteen people occupy five pages with local on the last page")
  func boundary() {
    var page = VideoPage(localUser: MockSeed.currentUser)
    page.update(participants: Array(MockSeed.standard.users.prefix(16)))
    #expect(page.pageCount == 5)
    for _ in 0..<7 { page.next() }
    #expect(page.index == 4)
    #expect(page.tiles.map(\.user.id.rawValue) == ["user-me", "user-11", "user-12", "user-13"])
  }
}
