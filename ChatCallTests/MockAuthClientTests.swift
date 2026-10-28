import Foundation
import Testing

@testable import ChatCall

struct MockAuthClientTests {
  @Test("Nonempty identity and six characters creates a process-local session")
  func signInStoresSession() async throws {
    let client = MockAuthClient()
    let session = try await client.signIn(
      credentials: Credentials(identity: " alex ", password: "123456"))
    #expect(session.user.id == UserID("user-me"))
    #expect(session.user.displayName == "alex")
    #expect(session.signedInAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(await client.currentSession == session)
    await client.signOut()
    #expect(await client.currentSession == nil)
  }

  @Test(
    "Blank, short, and dedicated invalid credentials fail with a typed error",
    arguments: [
      Credentials(identity: "  ", password: "123456"),
      Credentials(identity: "alex", password: "12345"),
      Credentials(identity: "invalid", password: "invalid")
    ])
  func invalidCredentials(credentials: Credentials) async {
    let client = MockAuthClient()
    await #expect(throws: AuthError.invalidCredentials) {
      try await client.signIn(credentials: credentials)
    }
    #expect(await client.currentSession == nil)
  }

  @Test("Signing out while sign-in is suspended prevents a late session from returning")
  func signOutInvalidatesPendingSignIn() async throws {
    let scheduler = ManualDemoScheduler()
    let client = MockAuthClient(scheduler: scheduler)
    let signIn = Task {
      try await client.signIn(credentials: Credentials(identity: "alex", password: "123456"))
    }
    #expect(await scheduler.waitForPendingSleep())
    await client.signOut()
    await scheduler.advance()
    await #expect(throws: CancellationError.self) { try await signIn.value }
    #expect(await client.currentSession == nil)
  }
}

struct DomainFixtureTests {
  @Test("Direct and group membership must be complete and unique")
  func conversationMembershipValidation() throws {
    let selfID = UserID("user-me")
    #expect(throws: ChatError.invalidMembers) {
      try Conversation(
        id: ConversationID("invalid"), kind: .direct, name: "Ava",
        memberIDs: [selfID], updatedAt: MockSeed.date)
    }
    #expect(throws: ChatError.invalidMembers) {
      try Conversation(
        id: ConversationID("invalid"), kind: .group, name: "Team",
        memberIDs: [selfID, selfID, UserID("user-ava")], updatedAt: MockSeed.date)
    }
    #expect(throws: ChatError.invalidMembers) {
      try Conversation(
        id: ConversationID("invalid"), kind: .group, name: "Team",
        memberIDs: [selfID, UserID("user-ava")], updatedAt: MockSeed.date)
    }
    #expect(throws: ChatError.groupNameRequired) {
      try Conversation(
        id: ConversationID("invalid"), kind: .group, name: "  ",
        memberIDs: [selfID, UserID("a"), UserID("b")], updatedAt: MockSeed.date)
    }
  }

  @Test("Fresh seed instances retain room ordering, message identities, and fixed dates")
  func seedIsDeterministic() throws {
    let seed = MockSeed.standard
    #expect(seed.conversations.map(\.id.rawValue) == ["conversation-ava", "conversation-team"])
    #expect(seed.messages.map(\.id.rawValue) == ["message-ava-1", "message-team-1"])
    #expect(
      seed.messages.map(\.sentAt) == [
        Date(timeIntervalSince1970: 1_700_000_000),
        Date(timeIntervalSince1970: 1_699_999_940)
      ])
    #expect(seed.conversations == MockSeed.standard.conversations)
    let data = try JSONEncoder().encode(UserID("user-ava"))
    #expect(try JSONDecoder().decode(UserID.self, from: data) == UserID("user-ava"))
  }
}
