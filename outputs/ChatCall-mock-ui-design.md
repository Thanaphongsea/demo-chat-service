# ChatCall Mock UI Design

## Intent

Create a new, buildable iOS app that demonstrates the product flow before the Login, Chat, and media APIs are available. The mock must be interactive enough for product review and must isolate data access behind replaceable interfaces so the later live integration does not require rewriting SwiftUI screens.

## Product decisions

- Temporary product name: `ChatCall`.
- Temporary bundle identifier: `com.example.ChatCall`.
- Minimum platform: iOS 26.0; portrait iPhone is the primary target.
- UI direction: native SwiftUI with restrained Liquid Glass, SF Symbols, Dynamic Type, light/dark mode, and no permanent brand assets.
- First release is mock-only: no real login, HTTP, chat WebSocket, WebRTC, push notification, CallKit, or PushKit traffic.
- Demo flow is complete and connected: Login → Chats → Direct/Group room → Create chat/group → Video call states.

## User experience

### Authentication

- Show username/email and password fields, validation, loading, invalid-credentials error, and a successful transition into the app.
- Seeded demo credentials accept any non-empty username with a password of at least six characters; a dedicated invalid credential fixture drives the error state.
- Logout returns to Login and clears all navigation paths. The mock session is process-local and resets on relaunch.

### Chat

- Main shell has `Chats`, `Calls`, and `Profile` tabs, each with its own navigation history.
- Chats shows seeded direct and group conversations, unread counts, last-message preview, timestamp, search, empty/loading/error fixtures, and a compose action.
- Compose supports one selected person for a direct chat and two or more people for a group; group creation requires a name.
- Chat rooms render stable message identities, incoming/outgoing bubbles, timestamps, delivery state, date separators, empty state, and a text composer.
- Sending updates the mock repository immediately, then advances the message from sending to sent/delivered through deterministic mock events.

### Video calls

- The video action in a direct room starts a 1:1 call. The video action in a group room immediately calls all current group members; it never opens a call-member picker.
- Calls tab contains history plus deterministic demo controls for incoming direct and group calls.
- Mock call states cover incoming, outgoing/ringing, active, reconnecting, declined, missed, and ended.
- Active 1:1 shows local and remote tiles. Active group shows local + up to three remote participants per page, stable ordering, paging, and page clamping as members leave.
- Controls simulate microphone, camera, camera flip, speaker, and end. Group calls reject more than 16 total participants with a visible capacity error.

## Architecture

- Use feature slices (`Auth`, `Conversations`, `ChatRoom`, `Calls`) over shared domain models and client protocols.
- Use Swift 6 strict concurrency. UI stores are `@MainActor @Observable`; mock mutable data lives in actors; domain values crossing isolation boundaries are `Sendable`.
- Inject `AuthClient`, `ChatClient`, and `CallClient` from the app root. Views depend on protocols and feature stores, never concrete mock actors.
- Use `AsyncStream` for chat and call events so live WebSocket/WebRTC implementations can preserve the same consumer interface.
- Keep navigation in enum routes and one `NavigationStack` per tab. Present compose and incoming-call flows with enum-driven sheets/full-screen covers.
- Use native Liquid Glass only for navigation, composer, and call-control surfaces. Message content and video tiles use opaque/high-contrast surfaces.
- Generate the Xcode project from a committed XcodeGen `project.yml` and commit the generated `.xcodeproj` too, so the project opens and builds even before XcodeGen is installed on another machine.
- Drive delayed mock transitions through an injected scheduler. Runtime mocks use short fixed delays, unit tests use a manual scheduler, and UI tests launch with an immediate scheduler.

## Considered approaches

1. **Feature slices with mock clients — selected.** Slightly more setup, but preserves screen code when live services arrive and enables deterministic tests.
2. **UI-only prototype.** Faster initially, but hard-coded view data would require a rewrite for API integration.
3. **Networking/media core first.** Rejected because Login/Chat contracts and the selected WebRTC artifact are not available yet.

## Non-goals

- Do not invent REST paths, JSON schemas, authentication token formats, chat socket events, or upload semantics.
- Do not add third-party chat, networking, database, image-loading, or WebRTC dependencies.
- Do not implement APNs, PushKit, CallKit, background calling, real media capture, or backend changes.
- Do not claim interoperability with Android/Web or compliance with the VoIP handoff acceptance tests during the mock phase.

## Acceptance

- The app builds and launches on the installed iPhone 17 Pro / iOS 26.5 simulator.
- A reviewer can complete every demo flow without editing source or waiting for nondeterministic timers.
- Unit tests cover validation, repository mutation, event handling, group creation, call transitions, the 16-person limit, video paging, logout reset, and cancellation.
- UI tests cover login, direct messaging, group creation/messaging, outgoing video, simulated incoming video, call controls, and logout.
- Every major screen has previews for primary, loading, empty, and failure states where applicable; interactive controls have accessibility labels/identifiers.

## Deferred integration seams

- Replace `MockAuthClient` after receiving identity login/refresh contract and test accounts.
- Replace `MockChatClient` after receiving chat REST/WebSocket contract, pagination, attachments, and roster behavior.
- Replace `MockCallClient` with the VoIP handoff implementation after chat identity and complete group rosters are available.
- Choose and pin the upstream WebRTC XCFramework only when starting real media integration.
