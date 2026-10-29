# Live API Integration (Auth hardening + Chat) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MockChatClient` with a `LiveChatClient` that talks to the real Jasmine gateway (REST `/v4/*` + Centrifugo realtime), on top of a hardened token lifecycle, while keeping the existing stores/UI unchanged.

**Architecture:** One authorised transport (`GatewayClient`) owns Bearer token, `X-Request-Id` check, retry and the `{ErrorCode}` envelope. Pure mappers convert wire JSON to the existing domain types (`Conversation`, `Message`, `ChatEvent`). `LiveChatClient` (actor) composes both and a `RealtimeConnection`. Business rules are copied from the reference web app (`<local>/chat-service-dev-webapp/webapp/lib/*`), not invented.

**Tech Stack:** Swift / SwiftUI, Swift Testing or XCTest as already used in `ChatCallTests`, `URLSession`, `centrifuge-swift` (SPM, version pinned by the team — decision D4).

**Spec:** `docs/integration/chat-client.md`, `docs/integration/auth-client.md`, web reference `webapp/lib/{auth,compat,conversations,history,send,groups,profile,wire,events}.ts`, `ios-handoff-2026-10-22/` (calls only — see Phase 2).

## Open decisions (answer before the task that needs them)

| # | Decision | Needed by | Default if unanswered |
|---|---|---|---|
| D1 | Is `/v4/*` + `/ws/connection/websocket` on the same host as `/v1/token` (the current `AuthConfiguration.baseURL` tunnel)? | Task 2 | Yes, one gateway |
| D2 | `listUsers()` has no endpoint in the web app. Where does the compose-screen directory come from? | Task 4 | Derive from peers in `get_list` + group members, names via `profile/portrait_get`; ask backend for a directory API |
| D3 | Does the web app send E2EE (Signal) bodies by default? iOS cannot decrypt. | Task 3 | Render non-text elements as a placeholder; plain text only on send |
| D4 | Which Centrifugo Swift client and version to pin | Task 6 | `centrifuge-swift` latest tag ≥ 2 weeks old |
| D5 | Group-call member cap: web app 1–3 others, handoff 15 others | Phase 2 | **Settled: handoff (15 others, 16 total, no picker)** |

## Global Constraints

- Project uses default MainActor isolation: wire/domain types and protocols are `nonisolated` and `Sendable` (match `AuthModels.swift`).
- Never log or print a JWT, password, TURN credential, message text or draft. Tokens are `AccessToken` (redacted description).
- Never put a JWT in a URL or query string.
- All timestamps from the wire are **Unix seconds** (`MsgTimeStamp`, `MsgTime`) — never milliseconds.
- Every `/v4` response must carry `X-Request-Id` or it did not pass the gateway (treat as failure, no retry).
- Retry only 429 and 5xx (bounded, jittered, max 5, 500 ms base, 30 s cap) and retryable `ErrorCode`s; same body on retry. 400/403 and other 4xx are terminal.
- 401 body `ErrorCode`: 70001 expired, 70003 illegal → refresh once then sign out; **70009 revoked → sign out, never refresh or retry**.
- Group history page ceiling 20 (`ReqMsgNumber`); C2C `MaxCnt` ≤ 20 (server does not clamp: 30 returns 90002).
- Room ids: DM = `dm_<min>_<max>` (byte-sorted user ids, single underscore); group = `grp_<GroupId>`; wire `conversationID` = `c2c_<peer>` / `group_<gid>`.
- Mock paths (`-demo-mock`, UI tests) must keep working; `AppDependencies.mock()` is untouched.

## Review Focus

1. HTTP 200 with `ErrorCode != 0` must throw, not decode as success (every `/v4` op does this).
2. Message with a non-text `MsgBody` element (image, custom/E2EE, empty array) or missing `lastMessage` must not crash or drop the conversation row.
3. Token expiring mid-session: one 401/70001 refreshes and retries once; 70009 signs out with zero further requests.
4. Real groups can have 1–2 members but `Conversation.init` requires ≥ 3 for `.group` — mapper must not throw away the whole list because of one small group.
5. REST `send` response and the `onRecvNewMessage` event for the same message must collapse to one `Message` (reconcile by `MsgRandom`, never by text).

---

## File Structure

| File | Responsibility |
|---|---|
| `ChatCall/Core/Clients/AccessTokenProvider.swift` (new) | Protocol: `validToken() async throws -> AccessToken`, `invalidate() async` |
| `ChatCall/Core/Clients/LiveAuthClient.swift` (modify) | Send `device_id`; implement `AccessTokenProvider` with refresh; map 401 codes |
| `ChatCall/Core/Clients/Gateway/GatewayConfiguration.swift` (new) | Gateway HTTPS/WSS base, overrides via launch args |
| `ChatCall/Core/Clients/Gateway/GatewayClient.swift` (new) | `post<T>(op:body:)` for `/v4/<op>`; retry; envelope; error mapping |
| `ChatCall/Core/Clients/Gateway/GatewayError.swift` (new) | `GatewayError` enum (unauthorized, revoked, forbidden, rateLimited, server, envelope(code,info), transport) |
| `ChatCall/Core/Clients/Gateway/ChatWire.swift` (new) | `Decodable` wire structs (`MsgObject`, `ConversationItem`, responses) |
| `ChatCall/Core/Clients/Live/ChatMapper.swift` (new) | Pure wire→domain mapping and DM/group id helpers |
| `ChatCall/Core/Clients/Live/LiveChatClient.swift` (new) | `actor LiveChatClient: ChatClient` |
| `ChatCall/Core/Clients/Live/RealtimeConnection.swift` (new) | Centrifugo connection on `user:<me>`, decoded events |
| `ChatCall/App/AppDependencies.swift` (modify) | Build live chat, keep calls mocked |
| `ChatCallTests/Support/StubTransport.swift` (new) | Scripted `HTTPTransport` (reuse the one in `LiveAuthClientTests.swift` if present — move it here) |
| `ChatCallTests/{GatewayClientTests,ChatMapperTests,LiveChatClientTests,RealtimeEventTests}.swift` (new) | One per unit |

---

### Task 1: Harden auth token lifecycle

**Files:**
- Create: `ChatCall/Core/Clients/AccessTokenProvider.swift`
- Modify: `ChatCall/Core/Clients/LiveAuthClient.swift`, `ChatCall/Core/Clients/SessionStore.swift` (persist `deviceID`)
- Test: `ChatCallTests/LiveAuthClientTests.swift`

**Interfaces:**
- Produces: `protocol AccessTokenProvider: Sendable { func validToken() async throws -> AccessToken; func invalidate() async }`; `LiveAuthClient` conforms. `AuthError` gains `.revoked` (70009).
- Consumes: existing `HTTPTransport`, `SessionStore`.

- [ ] **Step 1: Write failing tests** in `LiveAuthClientTests.swift`:
  - `signIn_sendsDeviceID`: request body JSON contains `device_id` equal to a stable per-install UUID; second sign-in sends the same value.
  - `validToken_refreshesWhenWithin60sOfExpiry`: stub returns token expiring in 30 s then refresh response; assert second request is `POST /v1/token/refresh` with `Authorization: Bearer <old>` and returned token is the new one.
  - `validToken_doesNotRefreshWhenFresh`: expiry +10 min → zero extra requests.
  - `refresh401With70009_throwsRevoked_andClearsSession`: body `{"ErrorCode":70009}` → `AuthError.revoked`, `currentSession == nil`, no second refresh attempt.
  - `refresh401With70001_clearsSession_throwsInvalidCredentials`.
  - `refresh_concurrentCallers_shareOneRequest`: two simultaneous `validToken()` → exactly one refresh request.
- [ ] **Step 2: Run** `xcodebuild test -only-testing:ChatCallTests/LiveAuthClientTests` → new tests FAIL (symbols missing).
- [ ] **Step 3: Implement.** Add `device_id` to `TokenRequest` (UUID generated once, stored in `UserDefaults`/Keychain item `deviceID`); implement `validToken()` with a single in-flight `Task<AccessToken, Error>` and a 60 s margin (`REFRESH_MARGIN` from `lib/auth.ts`); decode the 401 envelope `ErrorCode`; add `AuthError.revoked`.
- [ ] **Step 4: Run** the same command → PASS; also run `AuthStoreTests` to confirm `AuthStore` still compiles with the new error case (handle `.revoked` like `.unavailable` copy-wise; add a message string, no new UI).
- [ ] **Step 5: Commit** `git commit -m "feat(auth): device_id, token refresh provider, revoked handling"`

### Task 2: GatewayClient (authorised `/v4` transport)

**Files:**
- Create: `Gateway/GatewayConfiguration.swift`, `Gateway/GatewayClient.swift`, `Gateway/GatewayError.swift`, `ChatCallTests/Support/StubTransport.swift`
- Test: `ChatCallTests/GatewayClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct GatewayConfiguration: Equatable, Sendable { let httpBase: URL; var websocketURL: URL { get } ; init(defaults: UserDefaults = .standard) }
  nonisolated struct Envelope: Decodable, Sendable { let errorCode: Int; let errorInfo: String? }  // keys ErrorCode / ErrorInfo
  actor GatewayClient { init(configuration: GatewayConfiguration, tokens: any AccessTokenProvider, transport: any HTTPTransport = URLSession.shared, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) });
    func post<Response: Decodable & Sendable>(_ operation: String, body: some Encodable & Sendable) async throws -> Response }
  nonisolated enum GatewayError: Error, Equatable, Sendable { case unauthorized, revoked, forbidden, rateLimited, server(Int), envelope(code: Int, info: String), transport, invalidResponse, missingRequestID }
  ```
- Consumes: `AccessTokenProvider` (Task 1).

- [ ] **Step 1: Write failing tests** (`StubTransport` returns scripted `(Data, HTTPURLResponse)` per call; records requests):
  - `post_buildsRequest`: URL `…/v4/openim/sendmsg`, method POST, `Authorization: Bearer T`, `Content-Type: application/json`.
  - `post_httpOKButErrorCodeNonZero_throwsEnvelope`: `{"ErrorCode":93000,"ErrorInfo":"x"}` → `.envelope(code: 93000, …)`.
  - `post_missingRequestID_throws_noRetry`.
  - `post_429Then200_retriesWithSameBody` and `post_503ExhaustsAfter5Retries_throwsServer(503)` (inject `sleep` to avoid real waiting; assert delays ≤ 30 s).
  - `post_401With70001_invalidatesTokenAndRetriesOnce`; second 401 → `.unauthorized`.
  - `post_401With70009_throwsRevoked_noRetry`.
  - `post_403_throwsForbidden_noRetry`.
  - `post_cancellation_propagatesCancellationError`.
  - `post_neverLogsToken`: (inspect by asserting `String(describing: GatewayError)` has no token substring).
- [ ] **Step 2: Run** `-only-testing:ChatCallTests/GatewayClientTests` → FAIL.
- [ ] **Step 3: Implement** per Global Constraints retry policy; retryable `ErrorCode` set = the §4.2 list in `lib/errors.ts` (read `isRetryable` in `webapp/lib/compat.ts`/`errors.ts` and copy the exact codes into a `static let retryableCodes: Set<Int>`; 91000 is one). Decode `Envelope` first, then `Response`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(gateway): authorised /v4 transport with envelope and retry`

### Task 3: Wire models and ChatMapper (pure)

**Files:**
- Create: `Gateway/ChatWire.swift`, `Live/ChatMapper.swift`
- Modify: `ChatCall/Core/Domain/ChatModels.swift` (relax group member invariant — see Step 3)
- Test: `ChatCallTests/ChatMapperTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct WireMessage: Decodable, Sendable   // MsgKey, MsgId, From_Account, To_Account, GroupId, MsgSeq, MsgRandom, MsgTimeStamp, MsgBody:[{MsgType,MsgContent}], IsPlaceMsg, MsgFlagBits, IsPeerRead
  nonisolated struct WireConversation: Decodable, Sendable   // Type, To_Account, GroupId, conversationID, unreadCount, lastMessage, showName, MsgTime
  nonisolated enum ChatMapper {
    static func roomID(me: UserID, peer: UserID) -> String            // "dm_<min>_<max>"
    static func conversationID(_ w: WireConversation) -> ConversationID  // wire value, else c2c_<peer>/group_<gid>
    static func message(_ w: WireMessage, in: ConversationID, me: UserID) -> Message?
    static func conversation(_ w: WireConversation, me: UserID, members: [UserID]?) -> Conversation?
  }
  ```
- Consumes: domain types in `ChatModels.swift`, `AuthModels.swift`.

- [ ] **Step 1: Write failing tests** with literal JSON copied from `webapp/lib/*.test.ts` fixtures where available:
  - `roomID_isSortedSingleUnderscore`: `("u_bob","alice")` → `dm_alice_u_bob`.
  - `message_textElem_mapsTextAndSecondsTimestamp`: `MsgTimeStamp: 1761124800` → `sentAt == Date(timeIntervalSince1970: 1761124800)`.
  - `message_nonTextBody_yieldsPlaceholderText` (image, `TIMCustomElem`, `[]`) — never nil, never crash.
  - `message_recalled_isTombstone` (`IsPlaceMsg == 2` group, `MsgFlagBits == 8` C2C) → text `"Message was recalled"`.
  - `message_peerRead_mapsDelivered`; own message without `IsPeerRead` → `.sent`; incoming → `.delivered`.
  - `conversation_direct_membersAreMeAndPeer`.
  - `conversation_groupWithTwoMembers_isNotDropped` (Review Focus 4).
  - `conversation_missingLastMessage_isNilLastMessage`; `updatedAt` from `MsgTime` seconds.
- [ ] **Step 2: Run** `-only-testing:ChatCallTests/ChatMapperTests` → FAIL.
- [ ] **Step 3: Implement.** Placeholder policy (D3): text elements concatenated; otherwise `"[Unsupported message]"`. Domain change: `Conversation.init` currently throws unless group has ≥ 3 members; change the rule to `≥ 1` for `.group` and update the mock/`NewConversationStoreTests` expectations only where they assert the old minimum for **wire-loaded** groups (creation still requires ≥ 2 others — keep that check in `createGroup`, not in the model).
- [ ] **Step 4: Run** `ChatMapperTests`, `MockChatClientTests`, `NewConversationStoreTests` → PASS.
- [ ] **Step 5: Commit** `feat(chat): wire models and pure mapper`

### Task 4: LiveChatClient — read paths

**Files:**
- Create: `Live/LiveChatClient.swift`
- Test: `ChatCallTests/LiveChatClientTests.swift`

**Interfaces:**
- Produces: `actor LiveChatClient: ChatClient { init(gateway: GatewayClient, me: UserID, realtime: (any RealtimeConnection)? = nil) }` implementing `listConversations`, `listUsers`, `messages(in:)` now; other methods `throw ChatError.userNotFound` placeholder until Task 5 (tests below must not call them).
- Consumes: `GatewayClient.post`, `ChatMapper`.

- [ ] **Step 1: Write failing tests** (stub gateway responses from `webapp/lib/*.ts` shapes):
  - `listConversations_readsPinnedThenNormalCursorsUntilComplete`: op `recentcontact/get_list` body `{From_Account:me, TimeStamp, StartIndex, TopTimeStamp, TopStartIndex, AssistFlags:63}`; loops until `CompleteFlag == 3`; result de-duplicated by `conversationID`, newest first.
  - `listConversations_groupRosterIsFetchedFully`: for each group row call `group_open_http_svc/get_group_member_info` with offset pagination until `MemberNum` reached; never returns a truncated roster as complete — a failed page throws.
  - `messages_direct_pagesOnCursorNotCount`: `openim/admin_getroammsg` `{Operator_Account, Peer_Account, MaxCnt:20, LastMsgKey, MaxTime}`; stops when `Complete == 1`.
  - `messages_group_pagesBySeq`: `group_open_http_svc/group_msg_get_simple` `{GroupId, ReqMsgSeq, ReqMsgNumber:20, WithRecalledMsg:1}`; `IsFinished` 1 or 2 terminal.
  - `messages_returnsOldestFirstDeduplicated`.
  - `listUsers_derivesFromPeersAndGroupMembers_excludesMe_withNamesFromPortrait` (D2 default); portrait failure for one account falls back to the id, never fails the batch.
  - `errors_envelopeCodeMapsToThrown`, `cancellation_isNotServiceFailure`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** copying paging rules from `conversations.ts`, `history.ts`, `groups.ts`. Cap history to a bounded number of pages per call (first page + user-driven older pages are future work — return first page only, 20 messages, and note in `docs/integration/chat-client.md`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(chat): live conversation, history and directory reads`

### Task 5: LiveChatClient — writes

**Files:** Modify `Live/LiveChatClient.swift`; Test `LiveChatClientTests.swift`.

**Interfaces:**
- Produces: `send(text:to:)`, `createDirect(with:)`, `createGroup(name:members:)` on `LiveChatClient`.
- Consumes: Task 4 client, `ChatMapper.roomID`.

- [ ] **Step 1: Write failing tests:**
  - `send_direct_postsSendmsg`: op `openim/sendmsg`, body `{From_Account, To_Account, MsgRandom:<UInt32>, MsgId, MsgBody:[{MsgType:"TIMTextElem",MsgContent:{Text}}]}`; returns `Message` with `deliveryState == .sent`, server `MsgKey` as id.
  - `send_group_postsSendGroupMsg`: op `group_open_http_svc/send_group_msg`, nonce field is **`Random`** not `MsgRandom`, `GroupId` present.
  - `send_trimsAndRejectsBlank` → `ChatError.emptyMessage`, zero requests.
  - `send_retryUsesSameMsgRandom`: first attempt throws transport error, retry call with the same pending id reuses the nonce (hold nonce keyed by caller-supplied draft id; if API has no hook, document that `send` does not auto-retry and the store retries by calling `send` again — then assert a fresh nonce is **not** reused after success).
  - `createDirect_returnsLocalConversation_noNetwork`: conversation id `c2c_<peer>`, members `[me, peer]`, no `lastMessage`; self/blank peer → `.invalidMembers`/`.userNotFound`.
  - `createGroup_callsCreateGroup`: `{Owner_Account:me, Type:"Public", Name, MemberList:[{Member_Account}]}`; < 2 others → `.invalidMembers`; blank name → `.groupNameRequired`; > 50 members → `.invalidMembers`; returns conversation id `group_<GroupId>` with members including me exactly once.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Group `Type` string and any required `ApplyJoinOption` value: copy `GROUP_TYPE_PUBLIC` from `webapp/lib/groups.ts` verbatim. Nonce: `UInt32.random(in: 1...UInt32.max)`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(chat): live send, createDirect, createGroup`

### Task 6: Realtime events

**Files:**
- Create: `Live/RealtimeConnection.swift`
- Modify: `Live/LiveChatClient.swift` (`events()`), `ChatCall.xcodeproj` (SPM dependency, D4)
- Test: `ChatCallTests/RealtimeEventTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated protocol RealtimeConnection: Sendable { func start(tokens: any AccessTokenProvider) async; func stop() async; func events() -> AsyncStream<RealtimeEvent> }
  nonisolated enum RealtimeEvent: Equatable, Sendable { case newMessage(WireMessage), conversationChanged(WireConversation), messageRevoked(…), readReceipt(peer: UserID, at: Date), kicked, reconnected, unknown(name: String) }
  ```
  `LiveChatClient.events()` returns an independent `AsyncStream<ChatEvent>` per call.
- Consumes: `AccessTokenProvider`, `GatewayConfiguration.websocketURL` (`wss://<host>/ws/connection/websocket`), `ChatMapper`.

- [ ] **Step 1: Write failing tests** against a `FakeRealtime` feeding `RealtimeEvent`s:
  - `onRecvNewMessage_becomesMessageInserted`; own-sent message that already returned from `send` does not produce a second `Message` (same `MsgRandom` → `deliveryChanged` or no-op) — Review Focus 5.
  - `onConversationChanged_andOnNewConversation_becomeConversationUpdated`.
  - `onRecvC2CReadReceipt_becomesDeliveryChanged(.delivered)`.
  - `unknownEvent_isIgnoredNotFatal`.
  - `kicked_signsOut` (callback `onRevoked`) and `reconnect_triggersResync` (emits a resync marker so stores re-run `listConversations`).
  - `multipleSubscribers_eachGetAllEvents_terminationRemovesOnlyThatOne`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `CentrifugoRealtime` with `centrifuge-swift`: connect with `getToken` from `AccessTokenProvider`; the JWT `channels` claim already subscribes `user:<me>` (no explicit subscribe); decode publications `{Event, Payload, Timestamp, "Trace-Id"}` from `lib/events.ts` table (24 names; handle the 5 above, route the rest to `.unknown`).
- [ ] **Step 4: Run** `RealtimeEventTests` → PASS.
- [ ] **Step 5: Commit** `feat(chat): centrifugo realtime events`

### Task 7: Wire into the app and session handling

**Files:**
- Modify: `ChatCall/App/AppDependencies.swift`, `ChatCall/App/ChatCallApp.swift`, `ChatCall/App/AppRootView.swift` (or wherever `AuthStore` lives) 
- Test: `ChatCallTests/AppDependenciesTests.swift` (new), existing `AuthStoreTests`

**Interfaces:**
- Produces: `AppDependencies.live(configuration:)` returns `chat: LiveChatClient` (needs `me`, so build lazily after sign-in: `ChatClient` factory or `LiveChatClient` that reads `currentSession` from auth — pick the latter: `init(gateway:session: @Sendable () async -> UserID?)`).
- Consumes: Tasks 1–6.

- [ ] **Step 1: Write failing tests:** `live_usesLiveChat_mockUsesMock`; `launchWithDemoMock_keepsMocks`; `gatewayRevoked_triggersSignOut` (revoked error surfaces to `AuthStore` and clears session); `signOut_stopsRealtime`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** wiring; `-gatewayURL` launch override; calls remain `MockCallClient`.
- [ ] **Step 4: Run** the full suite `xcodebuild test -scheme ChatCall` → all pass (including UI-test-facing mocks).
- [ ] **Step 5: Commit** `feat(app): wire live chat behind auth`

### Task 8: Dev-stack verification and docs

**Files:** Modify `docs/integration/chat-client.md`, `docs/integration/auth-client.md`, `docs/qa/runtime-qa.md`.

- [ ] **Step 1:** Run the app on the simulator against the dev gateway with two test accounts (get from backend). Check: login, conversation list matches web app for the same account, open DM and group history, send from iOS → appears in web app tab, send from web → appears on iOS without reload, create group, mark read.
- [ ] **Step 2:** Record results (call: user ids redacted, no tokens) in `docs/qa/runtime-qa.md`.
- [ ] **Step 3:** Update `chat-client.md` checklist: tick what is now mapped, keep unresolved items (history pagination UI, idempotent retry, directory API, E2EE).
- [ ] **Step 4: Commit** `docs: record live chat integration status`

---

## Phase 2 (separate plan once D5 and WebRTC/push decisions are made)

Foreground calling against the VoIP origin (`VOIP_URL`, separate from the chat gateway), per `ios-handoff-2026-10-22/`. Order: **P2-1** `CallAPIClient` (create with fixed `Idempotency-Key`, inbox, actions, heartbeat 10 s) → **P2-2** `CallSessionStore` polling (1 s idle) → **P2-3** domain/UI extension for Join/Rejoin, `group_status`, `can_join`, creator end-all (current `CallState` cannot express them) → **P2-4** signaling WebSocket with `Authorization` header + `video_subscriptions` → **P2-5** WebRTC (pinned binary) with 4-tile paging → **P2-6** CallKit; **P2-7** APNs VoIP needs backend work first. The roster for "call everyone" comes from `LiveChatClient` (Task 4), which is why chat goes first.

## Self-review

- Spec coverage: auth (T1), transport (T2), mapping + invariants (T3), reads (T4), writes (T5), realtime (T6), wiring/sign-out (T7), verification/docs (T8); calls deferred explicitly.
- Types: `AccessTokenProvider`, `GatewayClient.post`, `ChatMapper.*`, `RealtimeConnection` are named identically wherever consumed.
- Review Focus 1→T2, 2→T3, 3→T1/T2, 4→T3, 5→T6.
