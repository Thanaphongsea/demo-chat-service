# Phase 2A: Live call signalling (no media) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace `MockCallClient` with a `LiveCallClient` that creates, answers, declines, joins, leaves and ends calls through the VoIP REST API, discovers incoming and joinable calls by polling, and keeps its lease alive with heartbeats. No audio/video yet (Phase 2B).

**Architecture:** `VoIPClient` (REST, token refresh, retry) → `CallMapper` (pure `CallInfo` → `CallSnapshot`, personal view) → `LiveCallClient` (actions, polling, heartbeat, events). The domain gains `canJoin`, `join` and `endForEveryone`; the store and views gain Join/Rejoin and Leave/End-for-everyone.

**Spec:** `ios-handoff-2026-10-22/{01_API_REFERENCE,02_CALL_FLOWS,05_ACCEPTANCE_TESTS}.md`, `contracts/openapi.json`, `docs/integration/call-client.md`, `GLOSSARY.md`.

## Global Constraints

- Nonisolated/Sendable domain and wire types, as in Phase 1. Never log JWTs, ICE credentials or message text.
- Create a call with `Idempotency-Key` header **and** `idempotency_key` body; a retry reuses both key and payload (including `callee_ids` order). After a timeout never mint a new key.
- 1:1 uses `callee_id`; group uses `callee_ids` (1–15, unique, excluding the caller). Never send both. More than 15 others → `CallError.capacityExceeded(maximum: 16)`. No member picker.
- Send `peer_id` explicitly (the session user id) on every call; `caller_id` explicit on create.
- Ringing timeout is 30 s from creation; heartbeat every 10 s while joined (lease 45 s); polling never renews a lease.
- Poll `GET /api/calls?peer_id=` every 1 s while idle. `calls` holds only `ringing`; `joinable_calls` holds missed/left/rejected calls of still-active groups.
- Rejoin button visibility uses `can_join` (missing = false) and `group_status`, never `status == ended` alone. Never auto-join from discovery.
- Action semantics: direct ringing caller → `cancel`; direct accepted → `end`; group → `leave`; group creator "end for everyone" → `end-all`.
- Errors: 401 refresh once then unauthorised; 403 stop; 404 stop polling that call; 409 re-read state; 429 backoff; 502/503 bounded retry keeping the idempotency key.
- Room ids: direct `dm_<min>_<max>`, group `grp_<GroupId>`; conversation ids `c2c_<peer>` / `group_<gid>`.

## Review Focus

1. Create retried after a timeout must not create a second call (same key, same payload).
2. The creator leaving a group that others still occupy must not look like "call ended for everyone".
3. A declined/missed/left group call with `can_join == true` must offer Join/Rejoin; with `can_join` absent or `group_status == ended` it must not.
4. A heartbeat or poll that fails transiently must not end the local call; a 404/terminal state must stop heartbeat and polling for that call.
5. A stale inbox snapshot arriving after the user answered must not show the incoming screen again.

## Tasks

### Task 1: VoIPClient (REST) — `Core/Clients/VoIP/{VoIPConfiguration,VoIPClient,CallWire}.swift`, test `VoIPClientTests`
- Produces: `VoIPConfiguration(baseURL:)` (+ `init(defaults:)` reading `voipURL`), `WireCallInfo`, `WireInbox`, `actor VoIPClient { create(CreateCallRequest, idempotencyKey:) ; inbox(peer:); call(id:peer:); perform(_ action: CallAction, id:peer:) }`, `CallAction` (`accept reject cancel join leave heartbeat end endAll`), `VoIPError`.
- Tests: request shapes and headers per action; 201 create decoded; retry on 502/503/transport reuses key and body; 401 refreshes once; 403/404/409/429 map to typed errors (409/404 expose the `call` from the error body when present); fractional-second RFC3339 dates decode.

### Task 2: CallMapper (pure) — `Core/Clients/Live/CallMapper.swift`, test `CallMapperTests`
- Produces: `CallMapper.snapshot(_ wire: WireCallInfo, me: UserID) -> CallSnapshot?`, `roomID(for: Conversation, me:)`, `conversationID(fromRoom:me:)`.
- Tests: the state table (direct caller/callee, group creator/invitee/joined/left/rejected/missed, `group_status == ended`), `canJoin` rules, participants include me, creator ringing → active once another participant is `joined`, bad data returns nil not a crash.

### Task 3: Domain, store, UI — `CallModels`, `CallClient`, `MockCallClient`, `CallStore`, `CallHistoryRow`, `CallsListView`, `CallControlsView`, `AppRouter`, `AppDependencies`
- `CallSnapshot` gains `var canJoin = false` and `var localUserID = MockSeed.currentUser.id`; `CallClient` gains `join(callID:)` and `endForEveryone(callID:)`; mock implements them (join → `invalidTransition`, endForEveryone = end). `CallStore` gets `join(_:)`, `endForEveryone()`, derives the local tile user from the snapshot, hides demo actions when `demoCalls == false`. Views show Join/Rejoin on history rows with `canJoin`, "Leave call" for group calls, and "End for everyone" for the creator.
- Tests: store `join` brings a history call back to active; `endForEveryone` calls the client; local audio-only marker uses `localUserID`; demo hidden; existing 152 tests still pass.

### Task 4: LiveCallClient actions — `Core/Clients/Live/LiveCallClient.swift`, test `LiveCallClientTests`
- `start/answer/decline/end/endForEveryone/join`, local mic/camera/speaker/flip state, demo methods throw. Fresh roster check lives in the store; the client validates 1–15 callees and builds room id and idempotency key.
- Tests: create payload (direct vs group, key in header and body, retry keeps both), capacity 16, answer/decline/join map to actions, end per call kind, leave vs end-all, errors map to `CallError`.

### Task 5: Monitoring — same file, test `LiveCallMonitoringTests`
- `poll()` (one cycle, injectable clock) + loop started by the first `events()` subscriber: incoming from `calls[ringing]`, joinable list kept for history, heartbeat every 10 s while joined, state refresh of the current call, terminal clears the call, stale incoming ignored after answer, transient failures tolerated, 404 stops.
- Tests per Review Focus 2, 4, 5.

### Task 6: Wiring and docs — `AppDependencies.live` uses `LiveCallClient` when a VoIP URL is configured, else keeps the mock; update `docs/integration/call-client.md`. Full unit suite green.

## Not in 2A
ICE, `/api/rooms`, WebSocket, WebRTC, CallKit, PushKit/APNs (Phase 2B/2C). **Live verification needs a reachable VoIP origin**: neither the dev tunnel (`/api/*` is 404) nor `localhost:8080` serves it today.
