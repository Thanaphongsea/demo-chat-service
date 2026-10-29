# ChatClient integration contract

`Core/Clients/ChatClient.swift` returns domain values, not transport DTOs. Replace the shared `chat` dependency in `AppDependencies` so list, compose, room, and call roster reads share the same source. `LiveChatClient` now implements this protocol against the Jasmine gateway (REST `/v4/<operation>` plus the Centrifugo socket); the mapping below is taken from the reference web app (`chat-service-dev-webapp/webapp/lib`). It is unit-tested against scripted responses and was exercised once against the dev gateway on 2026-10-29 with the `u_alice`/`u_bob` test accounts (see *Dev-stack check* below). `Codable` on a domain type is not a wire-contract decision.

## Live adapter (as built)

| Member | Wire mapping | Known limits |
|---|---|---|
| `listConversations()` | `recentcontact/get_list` (pinned and normal cursors until `CompleteFlag == 3`, page cap 20); each group's roster from `group_open_http_svc/get_group_member_info` (100 per page) | A short or failed roster page fails the whole list; one request set per group on every refresh. |
| `listUsers()` | No directory endpoint exists. Built from direct peers and group members, names from `profile/portrait_get` | The composer only offers people already related to you. Needs a backend directory API to start a chat with someone new. |
| `messages(in:)` | `openim/admin_getroammsg` (1:1, `MaxCnt` 20) / `group_open_http_svc/group_msg_get_simple` (`ReqMsgNumber` 20) | One page only (latest 20); no scroll-back. Older history needs a cursor in the protocol. |
| `send(text:to:)` | `openim/sendmsg` / `group_open_http_svc/send_group_msg` (group nonce field is `Random`) | Fresh nonce per call, no client retry: a lost response after the server accepted the message can duplicate it. Needs a client request id in the contract. Text only. |
| `createDirect(with:)` | None: a direct conversation exists after the first message | Name is the user id until the next list refresh. |
| `createGroup(name:members:)` | `group_open_http_svc/create_group` (`Type: Public`, at most 50 listed members) | Needs two other members. |
| `events()` | Centrifugo, server-side channel `user:<me>`: `onRecvNewMessage`, `onNewConversation`/`onConversationChanged`, `onRecvC2CReadReceipt`, `onKickedOffline` | `delivered` means the peer read a 1:1 message; group messages stay `sent`. A reconnect re-reads the conversation list but does not backfill an open room's messages. Other events are ignored. |

### Dev-stack check (2026-10-29)

`LiveStackSmokeTests` (opt-in, needs `TEST_RUNNER_CHATCALL_LIVE_PASSWORD`; it sends one message from `u_alice` to `u_bob`) passed against the dev gateway: login with `device_id` (the token carries `dev`, `sid` and `channels: [user:<me>]`), conversation list with a 3-member group roster, the DM history, the derived user list, a REST send, and delivery of that same message id to Bob over the Centrifugo socket. Observed: the only existing DM message is an E2EE `TIMCustomElem` (`jasmine/e2ee-signal`), so it shows as "[Unsupported message]". Not yet exercised against the real stack: group send/create, read receipts, reconnect resync, token refresh in a long session, kick/revoke.

Behaviours worth knowing: non-text message bodies (images, E2EE `TIMCustomElem`) show as "[Unsupported message]"; recalled messages show "Message was recalled"; every `/v4` answer is checked for a non-zero `ErrorCode` even on HTTP 200; a revoked (70009) or unauthorised answer ends the session and returns the app to Login. Launch override: `-gatewayURL`.


All throwing operations must cancel their underlying work and report cancellation distinctly from a service failure. Before committing a mutation, check task cancellation where the transport allows it. Cancellation after server acceptance cannot undo a message or group: the adapter needs reconciliation and idempotency from the backend contract. Stores discard stale completions by revision. Cancelling a view subscription must remove that observer without stopping other consumers of the shared client.

| Method | Required product behavior | Ordering/idempotency and missing mapping |
|---|---|---|
| `listConversations()` | Return authorized conversations with stable IDs, complete member IDs, preview, unread count and update time. The list sorts newest first with ID tie-breaks. Calls refresh this list before starting so they do not use the room's cached roster. | Define complete pagination, roster completeness/freshness, unread/read semantics, deletion, timestamps and authorization. Never return a silently truncated roster as complete. Snapshot may overlap events. |
| `listUsers()` | Return selectable people, excluding the signed-in user; compose deduplicates IDs and searches names. Rooms resolve incoming sender IDs to directory names; an unavailable/missing identity displays “Unknown member” while messages still load. | Define directory pagination, permission scope, deleted users, naming/identity updates and cache policy. A list limited to selectable people may not resolve all historical senders; add a supported member lookup when its contract exists. |
| `messages(in:)` | Load only the requested conversation. Empty succeeds; failure supports retry. Timeline groups by local day and orders by time then stable ID. | Define history pagination, timezone/date precision, edit/delete semantics, permissions and snapshot cursor. Duplicate IDs collapse. Room subscribes before snapshot fetch to buffer overlapping events. |
| `send(text:to:)` | Trim text, reject whitespace-only messages; return the accepted message and canonical server ID. UI inserts immediately, clears only the submitted draft, displays sending/sent/delivered, and retries a failed row in place. | Own insert events may precede return; reconcile by returned ID, never matching text. Concurrent identical messages remain distinct. The current API has no client request ID: safe retry after ambiguous acceptance requires an explicit backend idempotency contract and likely a protocol extension. |
| `createDirect(with:)` | Reject self/unknown users; reuse the existing direct conversation for the same pair or create one and return it. | Define atomic pair uniqueness and conflict/retry semantics across devices. Emit/return the same stable conversation ID. |
| `createGroup(name:members:)` | Require a nonblank trimmed name and at least two other unique valid members; include the current user exactly once. Return a conversation and navigate to its room. | Define server validation, group limits, name policy, creation idempotency and partial-failure handling. Call capacity is separately limited to 16 total people; do not silently truncate group membership. |
| `events()` | Give each consumer its own `AsyncStream<ChatEvent>` with conversation updates, message inserts and scoped delivery updates. | Subscribe before fetching snapshots. Upsert conversations/messages by ID. Delivery is monotonic (sending → sent → delivered), including delivery arriving before insert. Ignore other-room events. Termination removes the subscriber. The stream cannot throw: define reconnect, resync, error presentation and subscription completion before adapting a fallible transport. |

The mock publishes insert and conversation-preview updates before `send` returns, then schedules delivery changes. Snapshot/event duplicates are expected. Production needs server sequence/cursor or version semantics for stale conversation snapshots, reconnection replay, ordering gaps, and message edits; the current domain does not encode those guarantees. Do not infer a WebSocket protocol from these Swift events.

## Mock replacement checklist

- [x] Test accounts and a reachable gateway supplied (dev tunnel, `u_alice`/`u_bob`). Still no official gateway docs: the mapping comes from the reference web app. Authentication is the same JWT as VoIP.
- [x] Map every method and event above, including complete roster pagination for group calling (see *Live adapter*).
- [ ] Agree snapshot/subscription cursor, reconnect/replay, deduplication, idempotency, ambiguous-send retry and read/unread policies.
- [ ] Resolve historical sender names independently of selectable-user availability; define a fallback and directory failure policy.
- [ ] Preserve shared dependency ownership and cancellation; test snapshot/event races, duplicate deliveries, identical concurrent sends, logout and account switching with the adapter.
- [ ] Keep message text, drafts, tokens and private directory values out of logs and analytics.

See [AuthClient](auth-client.md) and [CallClient](call-client.md). Live networking remains deferred.
