# ChatCall

A native SwiftUI mock app for reviewing login, chat, and video-call flows before live services are available. This scaffold starts at the unauthenticated Login gate; later features add the interactive demo flow.

Requires Xcode 27.1 and the iPhone 17 Pro simulator running iOS 26.5. The app supports portrait iPhone on iOS 26.0+, uses Swift 6 with complete strict concurrency and default MainActor isolation, and has the temporary bundle identifier `com.example.ChatCall`.

Open `ChatCall.xcodeproj` and run the `ChatCall` scheme. The generated project is committed, so XcodeGen is only required when changing project configuration.

## Development

XcodeGen was installed using `brew install xcodegen`; the resolved version is **2.46.0**. Use that version to reproduce the committed project. SwiftLint **0.63.2** is used for linting (`brew install swiftlint` if needed). Formatting uses Xcode's bundled `swift-format`.

```sh
make generate      # Regenerate ChatCall.xcodeproj from project.yml
make build         # Build the app on the pinned simulator
make test-unit     # Run Swift Testing unit tests
make test-ui       # Run XCTest launch tests
make format-check  # Check Swift formatting without changing files
make lint          # Run SwiftLint without changing files
```

Every simulator command uses `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`, keeps build artifacts in ignored `DerivedData/`, and disables code signing for simulator builds. The shared `ChatCall` scheme includes the app, unit-test, and UI-test targets.

The mock phase has no live networking or media capture and does not request camera or microphone access.
