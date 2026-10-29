# ChatCall

A native SwiftUI mock app for reviewing login, direct/group chat, and video-call flows before live services are available. It starts at Login and runs entirely with deterministic in-memory clients. No server, credentials file, camera or microphone permission is required.

Requires Xcode 27.1 and the iPhone 17 Pro simulator running iOS 26.5. The app supports portrait iPhone on iOS 26.0+, uses Swift 6 with complete strict concurrency and default MainActor isolation, and has the temporary bundle identifier `com.example.ChatCall`.

Open `ChatCall.xcodeproj` and run the `ChatCall` scheme. The generated project is committed, so XcodeGen is only required when changing project configuration.

## Development

XcodeGen was installed using `brew install xcodegen`; the resolved version is **2.46.0**. Use that version to reproduce the committed project. SwiftLint **0.63.2** is used for linting (`brew install swiftlint` if needed). Formatting uses Xcode's bundled `swift-format` and `.swift-format`; SwiftLint includes app/test sources only, excluding generated build and scratch artifacts.

```sh
make generate      # Regenerate ChatCall.xcodeproj from project.yml
make build         # Build the app on the pinned simulator
make test-unit     # Run Swift Testing unit tests
make test-ui       # Run XCTest demo, regression and screenshot flows
make format-check  # Check Swift formatting without changing files
make lint          # Run SwiftLint without changing files
```

Every simulator command uses `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`, keeps build artifacts in ignored `DerivedData/`, and disables code signing for simulator builds. The shared `ChatCall` scheme includes the app, unit-test, and UI-test targets.

For a clean verification, run `make generate`, then `xcodebuild -project ChatCall.xcodeproj -scheme ChatCall clean`, followed by the commands above. `git diff --check` verifies whitespace. Do not use Nick Lockwood's separate SwiftFormat tool as the repository formatter: its defaults differ from the established style. The plan's literal `swiftformat --lint ChatCall ChatCallTests ChatCallUITests` also fails on installed SwiftFormat 0.61.1 because its CLI requires paths first. The compatible read-only invocation is `swiftformat ChatCall ChatCallTests ChatCallUITests --lint`; its style findings are advisory. `make format-check` is the binding formatting check.

## Mock credentials and demonstrations

Use `alex` / `123456`, or any nonblank username/email and password of at least six characters. `invalid` / `invalid` deterministically exercises invalid credentials. These are fixture values, not real accounts. Authentication, messages, groups and call history are in-memory; relaunch resets the mock clients. Sign-out clears authenticated UI, navigation, drafts and pending feature work.

1. Sign in → Ava Chen → type and send → observe delivery → video button → controls → End call → Done. Returning to Chats shows the new preview.
2. Compose → choose one person to open/reuse a direct chat. Choose two or more people → Continue → enter group name → Create group → send a message. The current user is included once.
3. Open Design Team (or a created group) → video button calls all current members immediately. No call-specific picker appears. Groups support at most 16 total call participants; larger rosters show an error. Select at least four other people during group creation to demonstrate paging; each page retains the local tile and at most three remote tiles. Previous/Next clamps at bounds.
4. Calls → Simulate incoming direct/group → Answer or Decline. In an active call, Simulate reconnect exercises recovery presentation. Simulate missed adds history. History retains Ended, Declined and Missed outcomes.
5. Profile → Sign out → Login. Chats also has a sign-out toolbar action.

Media tiles are explicitly simulated. Microphone/camera/speaker/flip controls change local mock state only. Calls use a delayed runtime scheduler so ringing/reconnecting can be inspected; fixture events are repeatable and never depend on the network.

Optional scheme launch arguments:

| Argument | Scenario |
|---|---|
| `-demo-immediateEvents` | Immediate deterministic delivery/call transitions for UI tests |
| `-demo-emptyConversations` | Empty Chats |
| `-demo-failConversationLoadOnce` | Retryable first Chats load failure |
| `-demo-failMessageSendOnce` | Retryable first message-send failure |

Only one chat failure/empty fixture is selected at a time (empty, then conversation failure, then send failure precedence). Xcode previews additionally cover loading, room empty/load failure, long messages, dark appearance and accessibility text.

`IntegrationQATests` captures Login, Chats, direct room, group room, incoming call and active group call as retained XCTest attachments. Final exported PNGs are in `outputs/screenshots/`; supplementary images show accessibility text and dark appearance. The task report records the actual checks and limits, including VoiceOver/physical-device work that cannot be inferred from screenshots.

## Architecture and live handoff

`ChatCallApp` injects `AppDependencies` into `AppRootView`. MainActor observable stores own feature state and cancellation; typed `AppRouter` paths own per-tab navigation. Protocols in `Core/Clients` isolate Auth, Chat and Call effects. Actor mocks share seeded domain values and a replaceable demo scheduler. SwiftUI views consume stores/protocol dependencies; concrete mock construction in feature files is limited to previews/fixtures. Replace dependencies at the root to begin adapter work.

Integration contracts and replacement checklists:

- [AuthClient](docs/integration/auth-client.md): identity/login/refresh/logout contracts still required.
- [ChatClient](docs/integration/chat-client.md): chat gateway/SDK, directory, roster pagination and events still required.
- [CallClient](docs/integration/call-client.md): maps the supplied `ios-handoff-2026-10-22` reference package and explicitly records model gaps before live adaptation.

The bundle identifier `com.example.ChatCall`, mock user/conversation/message/call IDs, and mock signed-in identity are temporary. Select the production bundle identifier, Apple team, capabilities, environment configuration and authenticated identity mapping before live integration. Root injection begins integration; domain additions for real auth, Join/Rejoin, shared group outcomes, history/errors and media lifecycle are still required.

HTTP/WebSocket/WebRTC, real camera/audio, push, APNs VoIP/PushKit/CallKit, token persistence/refresh, production signing and background calling remain deferred. The supplied VoIP backend currently uses FCM; it does not provide an APNs VoIP sender/registry. Never substitute PushKit tokens into its FCM registration endpoint. Simulator mock success does not establish iPhone interoperability or background/media capacity.
