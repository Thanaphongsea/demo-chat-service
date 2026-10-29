import Foundation
import Testing

@testable import ChatCall

/// Opt-in: runs the real clients against the dev gateway with the u_alice and u_bob test accounts.
/// Enable with `TEST_RUNNER_CHATCALL_LIVE_PASSWORD=<their shared password>` (xcodebuild strips the
/// prefix); it sends one message from u_alice to u_bob. The password is never stored in the repo.
nonisolated private let livePassword = ProcessInfo.processInfo.environment["CHATCALL_LIVE_PASSWORD"] ?? ""
nonisolated private let liveSmokeEnabled = !livePassword.isEmpty

@Suite(.enabled(if: liveSmokeEnabled))
nonisolated struct LiveStackSmokeTests {
  private struct Seat {
    let auth: LiveAuthClient
    let chat: LiveChatClient
    let realtime: CentrifugoRealtime
    let user: UserID
  }

  private func seat(_ name: String) async throws -> Seat {
    let auth = LiveAuthClient(
      configuration: AuthConfiguration(defaults: UserDefaults(suiteName: "smoke") ?? .standard),
      store: InMemorySessionStore(), deviceID: "ios-qa-\(name)")
    let session = try await auth.signIn(
      credentials: Credentials(identity: name, password: livePassword))
    let gatewayConfig = GatewayConfiguration()
    let realtime = CentrifugoRealtime(configuration: gatewayConfig, tokens: auth)
    let chat = LiveChatClient(
      gateway: GatewayClient(configuration: gatewayConfig, tokens: auth),
      currentUser: { await auth.currentSession?.user.id }, realtime: realtime,
      deviceID: "ios-qa-\(name)")
    return Seat(auth: auth, chat: chat, realtime: realtime, user: session.user.id)
  }

  @Test("Alice and Bob: read paths, then a message travels over REST and the socket")
  func endToEnd() async throws {
    let alice = try await seat("u_alice")
    let bob = try await seat("u_bob")
    print("SMOKE users:", alice.user.rawValue, bob.user.rawValue)

    let conversations = try await alice.chat.listConversations()
    print("SMOKE alice conversations:", conversations.map { "\($0.id.rawValue)|\($0.kind)|\($0.memberIDs.count)|\($0.name)" })
    let direct = try #require(conversations.first { $0.id == ConversationID("c2c_u_bob") })
    #expect(direct.memberIDs == [alice.user, bob.user])

    let history = try await alice.chat.messages(in: direct.id)
    print("SMOKE history:", history.count, history.map { "\($0.senderID.rawValue):\($0.text.prefix(24))" })

    let users = try await alice.chat.listUsers()
    print("SMOKE users:", users.map { "\($0.id.rawValue)=\($0.displayName)" })
    #expect(users.contains { $0.id == bob.user })

    // Bob listens on the socket, Alice sends.
    let events = await bob.chat.events()
    let marker = "ios smoke \(UUID().uuidString.prefix(8))"
    let received = Task { () -> Message? in
      for await event in events {
        if case .messageInserted(let message) = event, message.text == marker { return message }
      }
      return nil
    }
    try await Task.sleep(for: .seconds(2))  // let the socket connect
    let sent = try await alice.chat.send(text: marker, to: direct.id)
    print("SMOKE sent id:", sent.id.rawValue, sent.deliveryState)
    let arrived = try await withThrowingTaskGroup(of: Message?.self) { group in
      group.addTask { await received.value }
      group.addTask {
        try await Task.sleep(for: .seconds(15))
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      received.cancel()
      return first
    }
    print("SMOKE socket delivery:", arrived?.id.rawValue ?? "NONE")
    #expect(arrived?.id == sent.id)

    let afterHistory = try await bob.chat.messages(in: ConversationID("c2c_u_alice"))
    #expect(afterHistory.contains { $0.id == sent.id })

    await bob.chat.stopRealtime()
    await alice.chat.stopRealtime()
  }
}
