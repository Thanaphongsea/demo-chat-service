# ChatCall runtime QA

Date: 2026-10-29 (Asia/Bangkok)

Device: iPhone 17 Pro simulator, iOS 26.5, UDID `8E62AABB-232F-4018-B87D-7A8313911EEF`.

App: `com.example.ChatCall`, deterministic mock clients only. The walkthrough used the documented mock login and contains no production credentials or secrets. Simulator actions were made in the visible serve-sim mirror. The UI displayed 10:10–10:19 during the checks.

## Continuous manual walkthrough

1. Started at Login, entered the mock identity, and submitted. Chats appeared with seeded Ava Chen and Design Team rows.
2. Opened Ava Chen. The room showed the seeded “Ready to catch up?” message. Entered and sent `Hello`; it appeared as an outgoing bubble with `Delivered`.
3. Started video from the room header. The active screen identified Ava Chen, showed local `You` and remote `Ava Chen` tiles, and stated video/audio were simulated. Tapped End call; the screen showed `Call ended`; tapped Done.
4. Used New chat, selected Teammate 1 and Noah Williams, named the group `Team`, and created it. The room title was `Team`; it showed `No messages yet`. Sent `No`; the outgoing bubble showed `Delivered`.
5. Started group video. The call title was `Group call · 3 people`; tiles showed `You`, Teammate 1, and Noah Williams. All three fit on the page. A horizontal swipe produced no visible page change because this roster did not require paging. End call showed `Call ended`; tapped Done.
6. From Calls, selected Incoming direct call. The incoming screen showed Ava Chen and `Incoming video call`, with Decline and Answer. Tapped Answer; the active Ava Chen call controls appeared. Ended the call; `Call ended` appeared.
7. Simulated another incoming direct call and tapped Decline. The screen showed `Call declined`; returned with Done.
8. Opened Profile and tapped Sign out. The app returned to Login.

### Paging follow-up

Because the three-person group above correctly had no page to change, a separate live UI check used a larger roster. Signed into the standard mock app, selected Teammates 1–4, named the group `page`, and started video. The call showed `Group call · 5 people`, `Page 1 of 2`, local `You` plus Teammates 4, 1, and 2, and enabled Next. Tapping Next showed `Page 2 of 2`, `You` plus Teammate 3, with Previous enabled. Tapping Previous returned to page 1. End call showed `Call ended`. Thus the page controls were exercised with a roster large enough to require paging.

## Appearance, text size, motion, and fixtures

- Light appearance: `xcrun simctl ui <UDID> appearance` reported `light`; the app showed the light Login/Chats surfaces.
- Dark appearance: selected Dark in the simulator mirror. The app rendered a black Login background with light text; the mirror event log recorded `UI appearance dark`.
- Normal text: simulator mirror Text Size slider value `3` was the starting default (`large` content-size category).
- XXXL: moved the mirror Text Size slider to `6`; its event log explicitly reported `extra-extra-extra-large`. The Login text enlarged substantially.
- Accessibility XXXL: ran `xcrun simctl ui <UDID> content_size accessibility-extra-extra-extra-large`; a follow-up query returned that exact category. Login content was taller than the viewport. An upward swipe scrolled to the Sign in button and demo guidance, confirming they remained reachable. Restored content size to `large` afterward.
- Reduce Motion: switched it on; event log recorded `UI reduce-motion on`. While enabled, signed in, observed the retryable Chats failure screen, and tapped Try again; seeded Chats then appeared. The login and retry transitions remained usable. Restored Reduce Motion off after the check.
- Injected load failure: launched with `-demo-failConversationLoadOnce`, then signed in. Chats displayed `Couldn’t load chats`, `Unable to load chats. Please try again.`, and `Try again`. Tapping Try again loaded Ava Chen and Design Team.
- Empty conversations: launched with `-demo-emptyConversations`, then signed in. Chats displayed `No chats yet` and `Your conversations will appear here.`

## VoiceOver/accessibility findings and limitation

Enabled VoiceOver in the simulator mirror; the mirror recorded `UI voiceover on` and showed the iOS VoiceOver Gestures tutorial, which was dismissed with OK. The app accessibility overlay exposed Login as a heading; ChatCall/tagline and field labels as text; username and password as text fields; Show password as a button; and Sign in as a button. The username field exposed identifier `auth.username` in the native accessibility description. This confirms the Login accessibility hierarchy was present.

Manual VoiceOver traversal/activation of the requested Login, Chats, room composer/video, incoming call, active-call controls, and logout elements could not be completed through this simulator-control path. The serve-sim run explicitly reported: `Device Hub keyboard unavailable ... macOS Accessibility permission is not granted (System Settings > Privacy & Security > Accessibility); using legacy HID`. Concrete behavior: the bridge logged a one-finger drag and Tab key-down/up; tapping the username field put a blue focus outline on the field, but repeated double-click/tap did not open its keyboard or activate it. The accessibility-tree panel could inspect labels and frames, but its controls did not advance/activate the simulator's VoiceOver focus. No spoken announcement or VoiceOver focus transition could be verified. VoiceOver was switched off after diagnosis. This is a simulator HID/VoiceOver gesture limitation, not evidence that the other screens were traversed successfully. The macOS Accessibility permission was not changed.

The original XCTest attachment run remains the evidence for the other requested screen screenshots. No source code changed during this follow-up, and no defect was found requiring a regression.

## VoiceOver traversal follow-up (2026-10-29)

I retried the VoiceOver check through the native simulator surface, not only the serve-sim mirror. `xcrun simctl list devices booted` listed the iPhone 17 Pro (iOS 26.5, UDID above). The native Simulator application was not exposed by the desktop app inventory (`cua.getState()`); `cua.getApp("com.apple.iphonesimulator")` returned `Invalid app`. XcodeBuildMCP's `open_sim` reported success, but the resulting simulator remained accessible through Apple's Device Hub only. Device Hub's live iPhone 17 Pro view showed the app and accepted normal simulator screen taps and keyboard-capture input.

From that live view, I opened Settings → Accessibility. The visible categories were Hover Text, Display & Text Size, Motion, Spoken Content, Physical and Motor, Hearing, Speech, and Accessories; there was no VoiceOver control in the visible accessibility list. Settings search for `VoiceOver` returned `No Results for “Voiceover”`. I also inspected the supported `xcrun simctl ui` options; they are appearance, increase contrast, and content size, with no VoiceOver option. A read-only simulator preference query, `xcrun simctl spawn 8E62AABB-232F-4018-B87D-7A8313911EEF defaults read com.apple.Accessibility VoiceOverTouchEnabled`, returned `0`.

Result: I could not enable native VoiceOver in this simulator session, so I could not observe spoken announcements, VoiceOver focus traversal, or VoiceOver activation on Login, Chats, room composer/video, incoming-call controls, active-call controls, or logout. Device Hub's normal touch/keyboard input is not evidence of VoiceOver operation; I do not count it as traversal. The previous serve-sim diagnosis remains: its keyboard bridge reported missing macOS Accessibility permission and used legacy HID, with no focus advancement/activation. I did not change macOS permissions or simulator preference files. Therefore the requested VoiceOver traversal/activation finding remains unverified due to the available simulator accessibility tooling/runtime surface; the existing XCTest hierarchy evidence is not a substitute.

## Semantic accessibility traversal and activation (2026-10-29)

This is app-owned XCTest semantic/accessibility-surface evidence, not native VoiceOver evidence. It does not establish spoken announcements or VoiceOver rotor/focus order. Device: iPhone 17 Pro simulator, iOS 26.5 (build 23F77), UDID `8E62AABB-232F-4018-B87D-7A8313911EEF`; Xcode 27.1 (27A9275). The final focused run was `ChatCallUITests/SemanticAccessibilityTests.testCriticalAccessibilitySurfaceTraversalAndActivation`; result: 1 test passed, 0 failures, 106.724 seconds. The result bundle is `DerivedData/Logs/Test/Test-ChatCall-2569.10.29_10-50-13-+0700.xcresult` (`** TEST SUCCEEDED **`).

The test queried stable identifiers, required non-empty labels and hittability, and checked relative frame order where useful (login fields top-to-bottom, room video action above the composer, incoming Decline before Answer left-to-right, and active-call controls left-to-right). It activated password reveal/hide, Sign in, New chat, Ava and Noah selection, Continue, group-name entry/Create, group composer/send, group video, microphone/camera/speaker/flip, reconnect, End/Done, Chats tab, direct room composer/send/video, direct-call controls/End/Done, Calls tab, incoming Answer and End, incoming Decline/Done, Profile, Sign out, and verified return to Login. `performAccessibilityAudit(for: .all)` ran on Login, Chats, member picker, group details, group/direct rooms, group/direct active calls, incoming call, and Profile; the retained `Accessibility audit findings` XCTest attachment in the result bundle records the exact automated audit findings.

The first semantic run found an empty accessible label on `auth.username`; a targeted assertion failed before production changes. The next run found an empty label on the Chats room navigation link; another found an empty label on `compose.groupName`. Explicit labels were added for username/password, conversation row (name, kind, preview), and group name. The all-screen walkthrough was then exercised. The audit separately identified the password visibility control's accessible width as 23 pt and a too-small `call.reconnect` hit area. Regression assertions for 48×48 pt targets were added before production changes; explicit 48 pt frames/content shape were added to those two controls. A subsequent run passed the target-size assertions and activated both password visibility and reconnect.

`XCUIApplication.performAccessibilityAudit(for: .all)` ran on Login, Chats, member picker, group details, direct/group rooms, direct/group active calls, incoming call, and Profile. Its output was retained as the `Accessibility audit findings` attachment and exported from the final result bundle to `/tmp/task8-a11y-closeout.2Q03I0/C79C62CB-CC55-4788-B4FC-59303A2A66CB.txt` for review (57 lines/findings). Findings include contrast failures/nearly-passing contrast, clipping at larger Dynamic Type sizes (username and search fields among them), and partially unsupported Dynamic Type (group controls and empty room). The audit reported no small-hit-target finding after the 48-point password-toggle and reconnect controls were fixed. These are recorded, not represented as a clean audit or resolved by broad visual redesign in this closeout. These semantic assertions and automated audits do not substitute for native VoiceOver traversal or activation; the simulator/runtime limitation above still applies.
