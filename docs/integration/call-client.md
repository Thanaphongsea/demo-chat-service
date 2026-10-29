# CallClient integration contract

`Core/Clients/CallClient.swift` is a deterministic presentation boundary. Replace `calls` in `AppDependencies`; retain a single shared instance for history, operations and event observation. It currently models one local call, simulated media controls, terminal history, and a four-tile page (local plus three remotes). It does not implement network transport, camera/microphone capture, system calls or background delivery.

## Supplied future source

The external reference is `<local>/ios-handoff-2026-10-22/`, dated 22 October 2026. Read its `README.md`, `01_API_REFERENCE.md`, `02_CALL_FLOWS.md`, `03_IOS_IMPLEMENTATION.md`, `05_ACCEPTANCE_TESTS.md`, and `contracts/openapi.json` together. Preserve its manifest/checksum provenance; it includes working-tree source snapshots, so a commit alone is insufficient. It is a reference package, not an iOS SDK. Do not copy credentials or reference binaries into this app.

The handoff is the future source for HTTP actions, authenticated native WebSocket signaling, SFU negotiation, ICE, participant admission, heartbeat, recovery and per-page video subscriptions. This document deliberately defines no new endpoint or JSON format. Its existing identity JWT must come from the separate identity service. Reachable HTTPS/WSS configuration, identity refresh/login, complete chat roster gateway/SDK, Apple team/bundle/capabilities/environments and a pinned native WebRTC dependency still need delivery or selection.

## Current methods and future mapping

| Member | Current product behavior | Future mapping / unresolved contract |
|---|---|---|
| `currentCall` | Async nonthrowing snapshot, or nil; terminal snapshots may remain until a subsequent call. | Reconcile server personal/shared/participant state and authenticated identity on foreground/relaunch. Define expiry and transport failures; one snapshot enum cannot express all handoff states. |
| `history()` | Return completed calls newest first, with stable ID and Missed/Declined/Ended outcome. | Define persistent history source, pagination, errors, cross-device scope, duration and personal vs shared outcome. The handoff inbox is not a history API. This method cannot currently throw. |
| `startVideoCall(in:)` | Start direct or group, invite the complete conversation roster immediately, no call member picker. Require current user, known members, and at most 16 people total; reject another live call. Outgoing ringing progresses to active on a deterministic scheduler. | Refresh complete paginated roster, then map create/admission and fixed request idempotency key from the handoff. Preserve payload/key on timeout retry; reconcile accepted requests before another create. Local ringing is presentation, not a direct copy of creator's accepted server status. |
| `answer(callID:)` | Incoming → active for the matching call. | Map accept, then enable media only after authorization/accepted response and permissions. Coordinate CallKit answer/audio activation in the later system adapter. |
| `decline(callID:)` | Incoming → declined; store terminal history, no media. | Map reject. A rejected group invite may be rejoinable while the shared group remains active; current UI/protocol has no Join/Rejoin action. |
| `end(callID:)` | Ringing/active/reconnecting → ended; cancel delayed activation. | Action depends on direct/group, personal state and creator intent: outgoing direct cancel, accepted direct end, group leave/end, creator end-all are distinct in the reference. The current single End action must not be assumed to end the shared group for everyone. Extend model/UI before live mapping. |
| `setMicrophoneEnabled(_:callID:)` | Change local microphone state only during a controllable call. | Map real audio track/capture with permission and audio-session lifecycle. Handoff does not broadcast remote microphone badges. |
| `setCameraEnabled(_:callID:)` | Change local camera state and audio-only local tile. | Map capture/track lifecycle, permissions and errors. No wire media-type field exists to infer incoming voice/video intent. |
| `setSpeakerEnabled(_:callID:)` | Change local speaker control state. | Map audio route behavior and interruptions via AVAudioSession/CallKit; define route failure/result semantics. |
| `flipCamera(callID:)` | Toggle local front/back state. | Map native capture switch and device availability; confirm error behavior. |
| `demoIncomingCall(kind:)` | Deterministically inject incoming direct/group fixtures. | Demo-only. Real incoming discovery/system push must feed events from a separate adapter; never issue a fake network action for this method. |
| `demoMissedCall(kind:)` | Inject terminal incoming missed fixture/history. | Demo-only. Derive real missed invitations from server time/state (reference timeout 30 seconds from creation). |
| `demoReconnect(callID:)` | Active → reconnecting → active via scheduler. | Demo-only trigger. Future recovery closes old transport, guards callbacks by generation, checks personal accepted state and bounds retries per handoff. It must not silently auto-join a participant who has left. |
| `events()` | Independent `AsyncStream<CallEvent>` observers receive full snapshots. | Convert polling/signaling/system events into serialized snapshots; terminate subscribers independently. Supply resync/reconnect/error semantics because this stream cannot throw or encode transport errors. |

## Live adapter, phase 2A (signalling only)

`LiveCallClient` talks to the VoIP REST API at `VoIPConfiguration.dev` (a quick tunnel whose URL changes when restarted; override with `-voipURL`). Without a configured service (`voip: nil`) the app uses `UnconfiguredCallClient`: demo actions work, real conversations are refused with an explanation. It is unit-tested against scripted responses, and **its signalling was verified once against the dev VoIP service on 2026-10-29** (`LiveCallSmokeTests`): a direct call (create → ringing, answer → active, end), and a group call on `g_test` (decline → `can_join`, rejoin, leave keeps `can_join`, creator end-all clears it). The dev service's `/api/health`, `/api/ice` (STUN plus TURN over UDP and TCP) and JWT acceptance were checked too. Media signalling was then exercised in the simulator with real WebRTC against the real SFU (room, ICE, socket, offer, answer received; the call stayed up), both as two clients in one process and through the real UI (`LiveCallFlowTests`: alice rings over REST, bob answers in the app). No audio or video was heard or seen.

| Product action | Wire call |
|---|---|
| Start direct / group | `POST /api/calls` with `callee_id` / `callee_ids` (1–15), `Idempotency-Key` header and `idempotency_key` body; a retry after a timeout reuses the first key |
| Answer / Decline | `accept` / `reject` |
| End | direct ringing caller `cancel`, direct accepted `end`, group `leave` |
| End for everyone | group creator only: `end-all` |
| Join / Rejoin | `join`, offered only when the server says `can_join` and the group is still running |
| Incoming and joinable calls | `GET /api/calls?peer_id=` every 1 s while idle |
| Lease | `heartbeat` every 10 s while joined (direct ringing calls are only read) |

The personal `status`, shared `group_status` and `can_join` are mapped by `CallMapper` into `CallSnapshot` (`canJoin`, `localUserID`). A creator who leaves a group others still occupy is `.ended` for them but can rejoin. Transient poll failures never end a call; 404/403 end it locally; 401 returns the app to Login. Local microphone, camera, speaker and flip toggles change the snapshot only. **Not built:** a persistent history API, and a call-time roster refresh beyond the store's existing conversation refresh. Media and system integration follow below.

## Media and system calls (phases 2B and 2C)

Everything below is built and unit-tested against fakes, but **none of it has run against a real VoIP service, SFU, iPhone camera/microphone, CallKit UI or push**. No VoIP origin was reachable, the simulator has no camera, and the backend sends no APNs VoIP push.

**Media (`MediaSession`, `WebRTCPeer`).** When the server sees this device as `accepted` in a call that is still running (a group creator is in the room while the screen still rings), the client opens the room (`POST /api/rooms`), reads `/api/ice`, creates the peer connection, opens the media socket with an `Authorization` header (never in the URL), sends `video_subscriptions` **before** the first offer, then answers every server offer one at a time and queues remote ICE until a remote description is set. Roster comes from `room_peers`/`peer_joined`/`peer_left` (not from tracks), so audio-only members keep a tile. The screen asks for video only for the current page's three remotes. A lost socket recovers on a new generation, at most three times after 1, 2 and 3 seconds, checking the call's state with the server first; a successful answer resets the count, a definitive "no" (403/404, or no longer accepted) stops recovery and ends the call locally. Microphone permission denied is fatal for the call; camera denied continues audio-only.

**Dependency.** WebRTC is `stasel/WebRTC` 155.0.0 (a third-party prebuilt Google WebRTC xcframework, pinned; 156.0.0 was only two days old). The handoff says the team should choose and pin its own build; building from the upstream sources is the alternative if a prebuilt binary is not acceptable. `centrifuge-swift` 0.10.4 stays for chat.

**System calls (`SystemCallCoordinator`, `CallKitAdapter`).** CallKit is used only for calls delivered by a VoIP push; while the app is open the in-app screen is the call UI and the app manages audio itself. Reporting foreground calls to CallKit as well made it send an End action 40 ms after an in-app answer and never activate the audio session (seen in the simulator, `LiveCallFlowTests`). For CallKit-handled calls, answer, end and mute from the system UI drive the store and CallKit's audio activation is handed to WebRTC (`AudioSessionController`), with a 2-second fallback that activates audio itself if CallKit never does. Outgoing calls are not mirrored by default, so a call that goes to the background has no system call UI. Launch with `-callKitInApp` (Xcode: Edit Scheme → Run → Arguments) to mirror every call, incoming and outgoing, to CallKit for testing on a device; it is off by default because it is unverified there (see above).

**Push (`PushKitAdapter`).** It registers for VoIP pushes, reports each one to CallKit immediately, then reconciles with the server and ends the system call as unanswered if no matching call appears. The payload keys it reads (`call_id`, `caller_name`) are **a proposal**, not a contract. The token goes to `VoIPPushTokenSink`, whose only implementation logs that nothing was uploaded: the backend has no APNs VoIP registry or sender, and a PushKit token must never go to the FCM endpoint.

**Capabilities.** `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` and background modes `audio` and `voip` are set. Push Notifications/VoIP entitlements, bundle id, team and APNs environments still need the team's signing setup.

**Known risks to test on devices.** Receiver reuse after renegotiation (video is mapped by stream id, which the SFU sets to the user id); the 45-second lease versus the app being suspended or locked (heartbeats are a polling-loop timer, not a background task); Bluetooth and route changes; 16-camera load; iPhone-to-Web/Android interop; and dropping the media socket when the app is backgrounded. `LiveCallSmokeTests` (signalling only) is ready to run with `TEST_RUNNER_CHATCALL_LIVE_PASSWORD` and `TEST_RUNNER_CHATCALL_VOIP_URL`.

## Cancellation, ordering and idempotency

The store subscribes before operations/current snapshot/history fetch, deduplicates history by call ID, serializes controls while busy, rejects stale state regressions, and retires dismissed/previous IDs. Terminal calls cannot reopen from delayed active events. Duplicate identical snapshots are safe. A new live call must not replace another live call.

Throwing adapter operations must propagate task cancellation, stop underlying requests where possible, and check cancellation before local commit. A remote accepted action may outlive cancellation; return/reconcile its authoritative ID and clean up media/leases. Logout resets immediately, cancels operations/subscriptions, then drains pending operations and declines/ends any nonterminal result; stale operations/events must not present UI again. Cleanup must be safe to repeat and bounded by a defined live timeout policy. Cancelling a UI observer does not itself end a live call.

The mock's immediate actor mutations are not network idempotency guarantees. The handoff explicitly defines create request keys and retry payload stability. Live control/action retries must follow each action's server semantics and reconcile conflicts. Keep server revision/cursor and transport generation tracking in the adapter/coordinator; timestamps alone are not enough to order callbacks. After terminal state, cancel activation, heartbeat, polling and media callbacks for that generation.

## Mapping checklist before replacing the mock

- [x] Map separate personal `status`, shared `group_status`, participant status and `can_join` (missing means false); Join/Rejoin and creator end-all exist in domain, store and views.
- [ ] Supply identity/token refresh and authorized user/device/session mappings; remove mock `user-me` assumptions. Never put JWT in URLs/logs.
- [ ] Resolve complete roster freshness and >16/missing-member errors; preserve one-tap call-all behavior.
- [x] Bounded create retry with fixed idempotency key/payload; busy/conflict mapped (unit-tested; not yet run against a real service).
- [x] Accepted-only media: room preparation, dynamic ICE, authenticated socket, serialized SDP/server offers, pre-description ICE queue (tracks are mapped by stream id, not yet by mid; needs a device).
- [x] Video subscriptions for each page/roster/reconnect, before the first offer; audio-only members keep a slot.
- [x] Separate polling and heartbeat duties implemented and unit-tested; lifecycle suspension on a physical iPhone still to be tested.
- [x] Generation-guarded recovery, teardown, permissions, audio session, pinned WebRTC build. Still open: interruption/route changes and iPhone↔Web↔Kotlin interoperability tests on devices.
- [ ] APNs VoIP registry/sender, token rotation/environment/topic: **backend work, not done.** CallKit and the PushKit receiver exist on the app side; the token sink has no uploader and the payload is a proposal.
- [ ] Supply persistent history/error contracts and select production bundle/team/capabilities; no Apple signing material belongs in this repository.

Live HTTP/WebSocket/WebRTC, Join/Rejoin, CallKit/PushKit, APNs and real background/media validation remain deferred. Passing this mock app's simulator checks is not evidence for live interoperability, background delivery or 16-camera capacity.
