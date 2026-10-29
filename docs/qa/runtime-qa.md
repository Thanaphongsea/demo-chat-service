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
