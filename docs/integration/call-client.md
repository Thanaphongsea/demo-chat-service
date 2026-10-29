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

## Cancellation, ordering and idempotency

The store subscribes before operations/current snapshot/history fetch, deduplicates history by call ID, serializes controls while busy, rejects stale state regressions, and retires dismissed/previous IDs. Terminal calls cannot reopen from delayed active events. Duplicate identical snapshots are safe. A new live call must not replace another live call.

Throwing adapter operations must propagate task cancellation, stop underlying requests where possible, and check cancellation before local commit. A remote accepted action may outlive cancellation; return/reconcile its authoritative ID and clean up media/leases. Logout resets immediately, cancels operations/subscriptions, then drains pending operations and declines/ends any nonterminal result; stale operations/events must not present UI again. Cleanup must be safe to repeat and bounded by a defined live timeout policy. Cancelling a UI observer does not itself end a live call.

The mock's immediate actor mutations are not network idempotency guarantees. The handoff explicitly defines create request keys and retry payload stability. Live control/action retries must follow each action's server semantics and reconcile conflicts. Keep server revision/cursor and transport generation tracking in the adapter/coordinator; timestamps alone are not enough to order callbacks. After terminal state, cancel activation, heartbeat, polling and media callbacks for that generation.

## Mapping checklist before replacing the mock

- [ ] Map separate personal `status`, shared `group_status`, participant status and `can_join` (missing means false). Add discovery/Join/Rejoin and creator end-all as explicit domain/UI work; do not overload `.ended`.
- [ ] Supply identity/token refresh and authorized user/device/session mappings; remove mock `user-me` assumptions. Never put JWT in URLs/logs.
- [ ] Resolve complete roster freshness and >16/missing-member errors; preserve one-tap call-all behavior.
- [ ] Implement bounded create retry with fixed idempotency key/payload; verify busy/conflict/reconcile cases.
- [ ] Implement accepted-only media: room preparation, dynamic ICE, authenticated native socket, serialized SDP/server offers, pre-description ICE queue and track mapping from SDP mid/msid.
- [ ] Send video subscriptions for each page/roster/reconnect: local plus three stable remote slots, audio for everyone, audio-only members retain slots. Hiding tiles alone is insufficient.
- [ ] Implement separate polling and heartbeat duties (reference heartbeat 10 seconds, lease 45 seconds); test lifecycle suspension on physical iPhone.
- [ ] Add generation-guarded recovery, teardown, permissions/audio routing/interruption, pinned WebRTC build and iPhone↔Web↔Kotlin interoperability tests from the acceptance checklist.
- [ ] Design APNs VoIP registry/sender, token rotation/environment/topic and CallKit/PushKit integration with backend. The supplied backend currently has FCM registration/sending only; a PushKit token must never be sent to that FCM endpoint.
- [ ] Supply persistent history/error contracts and select production bundle/team/capabilities; no Apple signing material belongs in this repository.

Live HTTP/WebSocket/WebRTC, Join/Rejoin, CallKit/PushKit, APNs and real background/media validation remain deferred. Passing this mock app's simulator checks is not evidence for live interoperability, background delivery or 16-camera capacity.
