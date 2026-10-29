# ChatClient integration contract

`Core/Clients/ChatClient.swift` returns domain values, not transport DTOs. Replace the shared `chat` dependency in `AppDependencies` so list, compose, room, and call roster reads share the same source. No live chat endpoint, SDK, event envelope, pagination, or JSON contract has been supplied. `Codable` on a domain type is not a wire-contract decision.

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

- [ ] Supply official chat gateway/SDK/API docs, authentication, authorized user/conversation ID mapping, errors, and test accounts.
- [ ] Map every method and event above, including complete roster pagination for group calling.
- [ ] Agree snapshot/subscription cursor, reconnect/replay, deduplication, idempotency, ambiguous-send retry and read/unread policies.
- [ ] Resolve historical sender names independently of selectable-user availability; define a fallback and directory failure policy.
- [ ] Preserve shared dependency ownership and cancellation; test snapshot/event races, duplicate deliveries, identical concurrent sends, logout and account switching with the adapter.
- [ ] Keep message text, drafts, tokens and private directory values out of logs and analytics.

See [AuthClient](auth-client.md) and [CallClient](call-client.md). Live networking remains deferred.
