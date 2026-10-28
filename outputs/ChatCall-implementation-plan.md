# ChatCall Mock UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a polished, fully navigable iOS 26+ mock app for Login, direct/group chat, and direct/group video-call flows, with replaceable client protocols ready for future API/WebSocket/WebRTC integration.

**Architecture:** SwiftUI feature slices sit on `Sendable` domain models and three injected client protocols. `@MainActor @Observable` stores own UI state, while actor-based deterministic mocks own mutable data and emit `AsyncStream` events. The app uses enum routing, one navigation stack per tab, and restrained native Liquid Glass.

**Tech Stack:** Xcode 27.1, Swift 6, SwiftUI, Observation, Swift Testing, XCTest UI testing, XcodeGen, iOS 26.0 deployment target.

**Spec:** `outputs/ChatCall-mock-ui-design.md`

## Global Constraints

- Temporary product name is `ChatCall`; temporary bundle identifier is `com.example.ChatCall`.
- Target iPhone portrait on iOS 26.0+; verify on installed iPhone 17 Pro / iOS 26.5 simulator.
- No live HTTP, WebSocket, WebRTC, APNs, PushKit, CallKit, camera, microphone, or backend work in this phase.
- Do not invent live API paths or wire formats; all future integration points remain protocol-based.
- Use Swift 6 strict concurrency, default MainActor isolation, immutable `Sendable` domain values, and actors for mock mutation.
- Use native SF Symbols and system typography; no permanent logo or brand asset.
- Apply Liquid Glass only to navigation, composer, and call-control surfaces; preserve opaque/high-contrast message and video content.
- Group video starts with every current group member, has no call-member picker, allows 16 participants total, and renders local + three remote tiles per page.

## Review Focus

- Rapid navigation/logout must cancel event consumers and prevent stale mock callbacks from changing the new session.
- Empty, loading, invalid-login, and injected client-failure states must remain navigable and accessible.
- Direct/group creation must deduplicate selected users and reject invalid member counts or missing group names.
- Group membership changes during a call must preserve stable order and clamp an invalid video page.
- Dynamic Type, VoiceOver labels, light/dark mode, and Reduce Motion must keep core actions usable.

## Planned Structure

```text
project.yml
Makefile
ChatCall/
  App/                 # app entry, dependency graph, auth gate, tabs, routing
  Core/Domain/         # Sendable product models and typed IDs
  Core/Clients/        # AuthClient, ChatClient, CallClient contracts
  Core/Mocks/          # seeded actor implementations and demo scenarios
  DesignSystem/        # theme, avatar, state views, glass surfaces
  Features/Auth/
  Features/Conversations/
  Features/ChatRoom/
  Features/Calls/
ChatCallTests/          # Swift Testing unit/state tests
ChatCallUITests/        # end-to-end XCUITest flows
docs/integration/       # mapping checklist for later live clients
```

---

### Task 1: Reproducible Xcode Project and App Shell

**Files:**
- Create: `project.yml`, `Makefile`, `.gitignore`, `README.md`, `ChatCall.xcodeproj/`
- Create: `ChatCall/App/ChatCallApp.swift`, `ChatCall/App/AppRootView.swift`
- Create: `ChatCall/DesignSystem/AppTheme.swift`, `ChatCall/Resources/Assets.xcassets`
- Create: `ChatCallTests/ProjectSmokeTests.swift`, `ChatCallUITests/LaunchTests.swift`

**Interfaces:**
- Produces: one generated scheme named `ChatCall` containing app, unit-test, and UI-test targets.

- [ ] If `xcodegen` is absent, install it with `brew install xcodegen`; record the resolved version in `README.md`.
- [ ] Write `project.yml` with iOS 26.0, Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_STRICT_CONCURRENCY = complete`, generated Info.plist, and the temporary bundle identifier; do not add unused camera/microphone permissions in the mock phase.
- [ ] Add `Makefile` targets `generate`, `build`, `test-unit`, `test-ui`, `format-check`, and `lint`; all simulator commands target `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`.
- [ ] Write failing smoke tests asserting the app root exposes the unauthenticated gate and launches with the Login screen.
- [ ] Generate and commit `ChatCall.xcodeproj`, add the minimal app root/theme, and make both smoke tests pass; `.gitignore` excludes DerivedData but not the generated project.
- [ ] Run `make build`, `make test-unit`, and `make test-ui`; expect `BUILD SUCCEEDED` and zero failures.
- [ ] Initialize Git if needed and commit: `chore: scaffold ChatCall iOS project`.

### Task 2: Domain Models, Client Contracts, and Deterministic Mocks

**Files:**
- Create: `ChatCall/Core/Domain/AuthModels.swift`, `ChatModels.swift`, `CallModels.swift`
- Create: `ChatCall/Core/Clients/AuthClient.swift`, `ChatClient.swift`, `CallClient.swift`
- Create: `ChatCall/Core/Mocks/MockAuthClient.swift`, `MockChatClient.swift`, `MockCallClient.swift`, `MockSeed.swift`, `DemoScheduler.swift`
- Create: `ChatCall/App/AppDependencies.swift`
- Test: `ChatCallTests/MockAuthClientTests.swift`, `MockChatClientTests.swift`, `MockCallClientTests.swift`

**Interfaces:**
- Produces: `UserID`, `ConversationID`, `MessageID`, and `CallID` typed string wrappers conforming to `Hashable`, `Codable`, and `Sendable`.
- Produces: `AuthClient.signIn(credentials:) async throws -> Session` and `signOut() async`.
- Produces: `ChatClient.listConversations()`, `listUsers()`, `messages(in:)`, `send(text:to:)`, `createDirect(with:)`, `createGroup(name:members:)`, and `events() async -> AsyncStream<ChatEvent>`.
- Produces: `CallClient.startVideoCall(in:)`, `answer(callID:)`, `decline(callID:)`, `end(callID:)`, `setMicrophoneEnabled`, `setCameraEnabled`, `flipCamera`, `demoIncomingCall(kind:)`, and `events() async -> AsyncStream<CallEvent>`.
- Produces: `AppDependencies` holding `any AuthClient`, `any ChatClient`, and `any CallClient` and installed once at the app root.
- Produces: `DemoScheduler.sleep(for:) async throws`; runtime uses fixed short delays, unit tests use a manually advanced scheduler, and UI tests use an immediate scheduler selected by launch argument `-demo-immediateEvents`.

- [ ] Write failing model/fixture tests for stable IDs, direct/group invariants, seed ordering, and date determinism.
- [ ] Write failing auth tests: non-empty identity plus six-character password succeeds; invalid fixture throws typed `AuthError.invalidCredentials`; sign-out clears session.
- [ ] Write failing chat tests for conversation loading, user deduplication, direct reuse, group-name validation, message insertion, and ordered delivery-state events.
- [ ] Write failing call tests for valid transitions, invalid transitions, group call-all behavior, 16-person capacity rejection, and deterministic incoming scenarios.
- [ ] Implement immutable models, typed errors, client protocols, the injected scheduler variants, and actor-based mock clients without UI imports.
- [ ] Run `make test-unit`; expect all Task 2 tests to pass under Thread Sanitizer-disabled normal CI settings and strict concurrency to compile without warnings.
- [ ] Commit: `feat: add mock-ready domain clients`.

### Task 3: Authentication Gate and Login UI

**Files:**
- Create: `ChatCall/Features/Auth/AuthStore.swift`, `LoginView.swift`, `LoginForm.swift`
- Modify: `ChatCall/App/AppRootView.swift`, `AppDependencies.swift`
- Test: `ChatCallTests/AuthStoreTests.swift`, `ChatCallUITests/LoginFlowTests.swift`

**Interfaces:**
- Consumes: `AuthClient` and `Session` from Task 2.
- Produces: `@MainActor @Observable AuthStore` with `state`, `username`, `password`, `signIn()`, and `signOut()`; authenticated session is the single app-level auth source of truth.

- [ ] Write failing store tests for local validation, loading, successful session, invalid credentials, cancellation, duplicate-submit suppression, and logout reset.
- [ ] Write failing UI tests for disabled login, validation copy, error presentation, secure-entry toggle, successful transition, and logout returning to Login.
- [ ] Implement the auth gate and form using native text fields, glass-prominent primary action, progress/error states, keyboard submit, Dynamic Type, and accessibility identifiers.
- [ ] On logout, cancel feature tasks and replace all tab routers before showing Login.
- [ ] Add previews for default, filled, loading, error, dark mode, and accessibility text sizes.
- [ ] Run targeted unit/UI tests, then `make build`; expect all to pass without warnings.
- [ ] Commit: `feat: build mock login flow`.

### Task 4: Tab Shell, Conversation List, Search, and States

**Files:**
- Create: `ChatCall/App/AppTab.swift`, `AppRouter.swift`, `AuthenticatedShellView.swift`
- Create: `ChatCall/Features/Conversations/ConversationListStore.swift`, `ConversationListView.swift`, `ConversationRow.swift`
- Create: `ChatCall/DesignSystem/AvatarView.swift`, `AsyncStateView.swift`, `UnreadBadge.swift`
- Test: `ChatCallTests/ConversationListStoreTests.swift`, `ChatCallUITests/ConversationListTests.swift`

**Interfaces:**
- Consumes: `ChatClient.listConversations()` and `ChatClient.events()`.
- Produces: tab-local `RouterPath` and `AppRoute`; `ConversationListStore` exposes load/search/event-reduction behavior.

- [ ] Write failing tests for loading/success/empty/failure, stable sorting, unread updates, search matching names/message previews, event cancellation, and stale-event rejection after logout.
- [ ] Write failing UI tests that verify Chats/Calls/Profile tabs, direct/group badges, unread count, search, empty fixture, retry, and opening a room.
- [ ] Implement one `NavigationStack` per tab with typed routes and a centralized destination mapper.
- [ ] Implement the conversation list and reusable state/avatar components; use glass for chrome only and opaque rows/content.
- [ ] Add deterministic preview fixtures for populated, empty, loading, failed, dark, and large-text states.
- [ ] Run Task 4 tests plus `make build`; expect zero failures and no strict-concurrency diagnostics.
- [ ] Commit: `feat: add conversation shell and list`.

### Task 5: New Direct Chat and Group Creation

**Files:**
- Create: `ChatCall/Features/Conversations/NewConversationStore.swift`, `NewConversationView.swift`, `MemberPickerView.swift`, `GroupDetailsView.swift`
- Modify: `ChatCall/App/AppRouter.swift`, `ConversationListView.swift`
- Test: `ChatCallTests/NewConversationStoreTests.swift`, `ChatCallUITests/NewConversationTests.swift`

**Interfaces:**
- Consumes: `ChatClient.listUsers()`, `createDirect(with:)`, and `createGroup(name:members:)`.
- Produces: direct creation for exactly one selected user; group creation for two or more unique selected users plus the current session user and a non-blank name.

- [ ] Write failing tests for search, selection toggling, deduplication, one-person direct routing, group-name validation, request-in-flight suppression, typed errors, and cancellation.
- [ ] Write failing UI tests for creating/opening a direct chat and creating/opening a named group.
- [ ] Implement an enum-driven compose sheet, searchable member picker, selected-member chips, and group-details step.
- [ ] Ensure this picker creates conversations only; the video button in an existing group never presents it.
- [ ] Run Task 5 tests and all conversation tests; expect zero failures.
- [ ] Commit: `feat: add direct and group creation`.

### Task 6: Direct and Group Messaging

**Files:**
- Create: `ChatCall/Features/ChatRoom/ChatRoomStore.swift`, `ChatRoomView.swift`, `MessageBubble.swift`, `MessageComposer.swift`, `DateSeparator.swift`
- Modify: `ChatCall/App/AppRouter.swift`
- Test: `ChatCallTests/ChatRoomStoreTests.swift`, `ChatCallUITests/MessagingFlowTests.swift`

**Interfaces:**
- Consumes: `ChatClient.messages(in:)`, `send(text:to:)`, and chat events scoped by conversation ID.
- Produces: ordered room state, trimmed message sending, sending/sent/delivered/failed rendering, retry for failed mock messages, and scroll-target IDs.

- [ ] Write failing tests for initial load, empty state, whitespace rejection, optimistic insertion, delivery progression, failed-send retry, wrong-room event filtering, duplicate-event idempotency, cancellation, and stable chronological grouping.
- [ ] Write failing UI tests for sending in direct/group rooms, delivery-state change, retry fixture, keyboard submit, and returning with the conversation preview updated.
- [ ] Implement message list/bubbles/composer with explicit load/error/empty states and a high-contrast content surface.
- [ ] Add the video action to the room toolbar; route only to the call start request owned by Task 7.
- [ ] Add previews for direct/group, incoming/outgoing, long text, failure, dark mode, and accessibility text.
- [ ] Run Task 6 tests plus the complete unit suite; expect zero failures.
- [ ] Commit: `feat: add mock direct and group messaging`.

### Task 7: Video Call State Machine and Mock Call UI

**Files:**
- Create: `ChatCall/Features/Calls/CallStore.swift`, `CallsListView.swift`, `CallHistoryRow.swift`, `IncomingCallView.swift`, `OutgoingCallView.swift`, `ActiveCallView.swift`, `VideoTileView.swift`, `CallControlsView.swift`, `VideoPage.swift`
- Modify: `ChatCall/App/AppRouter.swift`, `AuthenticatedShellView.swift`, `ChatRoomView.swift`
- Test: `ChatCallTests/CallStoreTests.swift`, `VideoPageTests.swift`, `ChatCallUITests/VideoCallFlowTests.swift`

**Interfaces:**
- Consumes: all `CallClient` operations/events from Task 2 and complete conversation membership from `ChatClient`.
- Produces: a single active-call state machine and full-screen presentation; `VideoPage` maps local participant plus stable chunks of three remote participants.

- [ ] Write failing state tests for direct/group outgoing, call-all membership, incoming answer/decline, missed/ended/reconnecting, duplicate events, invalid transitions, logout cancellation, and capacity error.
- [ ] Write failing paging tests for local + three remote tiles, stable ordering, next/previous, roster change, member departure, page clamp, audio-only placeholder, and 16-person boundary.
- [ ] Write failing UI tests for outgoing direct, outgoing group without member picker, simulated incoming direct/group, answer/decline, microphone/camera/speaker/camera-flip controls, paging, reconnect banner, and end.
- [ ] Implement the Calls history/demo-scenarios screen and deterministic buttons for incoming direct/group calls.
- [ ] Implement incoming/outgoing/active full-screen views. Use static gradients/avatars as mock video, opaque tiles, and a grouped glass control dock.
- [ ] Respect Reduce Motion for call transitions and provide VoiceOver labels/state values for every control and participant tile.
- [ ] Run Task 7 tests, all unit tests, and video UI tests; expect zero failures.
- [ ] Commit: `feat: add mock video call flows`.

### Task 8: Integration Readiness, Visual QA, and Final Verification

**Files:**
- Create: `docs/integration/auth-client.md`, `chat-client.md`, `call-client.md`
- Modify: `README.md`
- Modify: previews, accessibility identifiers, and fixtures across existing feature files only where verification finds gaps.
- Test: all `ChatCallTests/` and `ChatCallUITests/`.

**Interfaces:**
- Documents: for each protocol method, required product behavior, cancellation semantics, event ordering/idempotency rules, and which missing backend contract must be supplied; no speculative endpoint or JSON shape.

- [ ] Add a contract-mapping checklist for replacing each mock client and record the VoIP handoff as the future source for `CallClient` behavior.
- [ ] Add README commands for project generation, build, tests, mock credentials, demo scenarios, architecture, temporary identifiers, and deferred live integrations.
- [ ] Run `swiftformat --lint ChatCall ChatCallTests ChatCallUITests` and `swiftlint --strict`; fix only source findings, then rerun until clean.
- [ ] Run `make generate`, `make build`, `make test-unit`, and `make test-ui` from a clean generated-project state.
- [ ] Launch on iPhone 17 Pro / iOS 26.5 and manually exercise Login → direct chat → send → video → end; group creation → message → group video → page; incoming answer/decline; logout.
- [ ] Verify light/dark mode, XXXL and accessibility text sizes, VoiceOver traversal, Reduce Motion, empty/failure fixtures, and no privacy-sensitive values in logs.
- [ ] Capture final simulator screenshots for Login, Chats, direct room, group room, incoming call, and active group call in `outputs/screenshots/`.
- [ ] Commit: `docs: finalize mock app integration handoff`.

## Completion Gate

- All generated-project, build, unit, UI, lint, and format commands pass from the documented commands.
- The app demonstrates every accepted flow using only deterministic mocks.
- No screen imports or constructs a concrete mock client directly; swapping root dependencies is sufficient to begin live integration.
- Live API/WebSocket/WebRTC work remains explicitly deferred until its contracts and artifacts are supplied.
