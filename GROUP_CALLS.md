# Group calls: comparison against Signal, and what is left to build

_Last updated: 2026-09-26. Supersedes the roadmap role of `CALLS_PLAN.md`,
which remains the chronological record of how the call path was built and what
each bug turned out to be._

Reference implementation: `signalapp/Signal-Desktop`, read at
`ts/services/calling.preload.ts`, `ts/calling/VideoSupport.preload.ts`,
`ts/util/zkgroup.node.ts`, `ts/groups.preload.ts`, and the shipped
`app.asar`. Claims below were checked against that source rather than against
documentation or a summary of it.

Status vocabulary: **match** — same behaviour, verified. **diverge** — different
behaviour, recorded below with whether the difference is deliberate. **missing** —
not implemented here.

---

## 0. Status

**Two-party group call audio works in the receive direction, confirmed against a
real second client on 2026-09-26.** A member of the group is heard, clearly, in
this client, during a live call.

That was the last of three byte-length bugs in the same family, each silent, each
total, and each reported by nothing:

| # | Fault | Effect |
|---|---|---|
| 1 | Member id 64 bytes where the SFU hashes 65 | No participant resolved; device list empty; RingRTC disabled audio outright. Total silence. |
| 2 | Sender id 17 bytes where RingRTC's `UserId` is 16 | Every inbound media key discarded; incoming audio undecryptable. Silence inbound. |
| 3 | Microphone never opened — `set_audio_warmup` never called | Outgoing track carried nothing. Silence outbound. |

**Both directions now confirmed working** against a real second client on
2026-09-26.

**A fourth fault, found immediately afterwards and now fixed:** muting a group call
only set the heartbeat flag. RingRTC says outright that this is the host's job —
at the end of `set_outgoing_audio_muted_inner`:

```rust
// We don't modify the outgoing audio track.  We expect the app to handle that.
```

So the call was told it was muted and transmitted anyway: the UI, the heartbeat and
every other participant agreed the microphone was off while it was very much on.
The 1:1 path has always disabled the track; the group path did not. The track is
now disabled rather than the device closed, so unmuting is immediate.

This is the worst class of bug in the set, because it is not a failure to work — it
is a claim to others that something is off when it is on.

## 1. Where this actually stands

The group call joins Signal's production SFU. This is verified end to end and has
been repeatedly observed live:

- ZK group credential fetched, presented, and **redeemed natively** at the CDN.
- `PUT /v2/conference/participants` → `200`; `join: Joined(<demux id>)`.
- `state: Connected`, which is the **ICE** state and genuinely connects.
- Media keys sent and received; heartbeats carrying mute state.
- Rings composed and sent **by RingRTC**, not by the host, so the ring id and
  RingRTC's outgoing ring state are correct.
- Roster supplied on every call path; inbound signals delivered once, natively.

What is not yet true is that anyone can hear anything. The cause was found on
2026-09-26 and is described in `CALLS_PLAN.md`; in short, the member id handed to
RingRTC was 64 bytes where the SFU hashes 65, so no participant could ever be
resolved, an empty device list read as "nobody else is here", and RingRTC switched
off audio recording, outgoing media and playout together. **The fix is in and
unverified against a live call.** Nothing else in the chain is known to be broken.

---

## 2. Comparison

### 2.1 Bringing a call up

| Step | Signal | This client | Status |
|---|---|---|---|
| UI never constructs the native call | Redux thunk → `CallingClass` | view → `GroupCallController` → `CallManager` | match |
| Group parameters come from the conversation | `{groupId, publicParams, secretParams}` | master key → group id, secret params, proof | match |
| Permissions requested before connecting | `#requestPermissions(hasLocalVideo)` | `ensureMicrophonePermission()`, camera only on request | diverge (see §4) |
| Permission denied still joins | logs "allow joining group call" | cancels the call | diverge, deliberate |
| `connectGroupCall` is idempotent and reuses a live client | yes | inbound signal prepares a client; answer reuses it | match |
| Membership proof supplied from an observer callback | `requestMembershipProof` → `fetchMembershipProof` | `RequestMembershipProof` → fetch/redeem/present | match |
| Outgoing audio/video mute set after connect, before join | `setOutgoingAudioMuted` / `setOutgoingVideoMuted` | both, on both paths | match |
| Start local media capture | `enableCaptureAndSend` | — | n/a, see below |
| Ring the group, separately from joining | `ringAll()` then `join()` | vendored `ring_group`, then join | match |
| `join()` | `groupCall.join()` | `joinGroupCall` | match |
| System mute mirrored into the call | `muteStateChange.setIsMuted` | — | missing |

**`enableCaptureAndSend` is video only.** It starts the camera and attaches the
video sender and never touches audio. Audio capture is entirely inside RingRTC's
native layer, driven by the track built with the peer connection factory, which
this client already does. This was checked specifically because the absence of an
equivalent looked like a plausible missing audio step. It is not one.

### 2.2 Identifying participants

This is where the silence lived, so it is worth being exact.

| Step | Signal | This client | Status |
|---|---|---|---|
| Member list built from the group's own state | `getMembershipList(conversationId)` | `NativeGroupRoster.load(masterKeyHex:)` | match |
| Ciphertext freshly derived from secret params | `encryptServiceId(cipher, aci).serialize()` | `secret_params.encrypt_service_id(aci)` then serialize | match |
| **Whole serialization, reserved byte included** | 65 bytes | 65 bytes (was 64) | match, fixed |
| Service id is the bare 16 bytes, not the 17-byte kind-prefixed form | `uuidToBytes(aci)` | `service_id_fixed_width_binary()[1..]` | match |
| `setGroupMembers` from the `requestGroupMembers` callback | yes | yes | match |
| `setGroupMembers` from a membership-changed hook | `groupMembersChanged` | — | missing, low impact |
| Set on the `requestGroupMembers` callback only | yes | yes | match |

Two things that looked like bugs and are not, both confirmed in Signal's source:

- **The ordering is right.** Members are supplied from RingRTC's request
  callback, which is what this client does. Answering a call and supplying
  members *afterwards* is correct, and RingRTC re-requests once members change.
- **The encryption is deterministic.** `zkcredential` computes
  `E_A1 = a1·M1; E_A2 = a2·E_A1 + M2` with no nonce, so re-deriving a member id
  gives identical bytes and cannot itself cause a mismatch.

The chain that produced silence, all of it now understood:

1. SFU returns `hex(sha256(GroupMemberId))` per participant.
2. RingRTC resolves each against `hex(sha256(member_id))` for the members the host
   supplied (`group_call.rs:3304`).
3. A 64-byte id against the SFU's 65 could never match, so `user_id` was `None`.
4. An unresolvable participant is dropped from the device list **silently**.
5. An empty device list makes `compute_send_rates(0, _)` choose the all-alone
   branch, which disables recording, outgoing media **and** playout.
6. Silence in both directions, with the call joining perfectly and reporting
   nothing at any point.

### 2.2b The second bug: the sender id

Fixed on 2026-09-26, the same day and the same family as the member id.

The first instrumented run after the member-id fix produced:

```
sfu peek joined=1 identified=1 resolved=1 demux=[4188081344]
group devices client=2 n=1 keys=0 unmuted=0 spoke=1 video=0
```

`resolved=1` and `n=1` — the member map works and a participant exists. `spoke=1`
— someone is genuinely transmitting. But `keys=0`: **their media key never
arrived**, and without it not one incoming frame can be decrypted.

`group_call.rs:3757` applies an inbound media key on strict equality:

```rust
if device.user_id == user_id { … }   // else: "the demux ID doesn't make sense"
```

The left side is built from the member map. The right came from
`received_call_message`, which was being handed
`service_id_fixed_width_binary()` — a **17**-byte kind-prefixed form — where
RingRTC's `UserId` is the bare 16. One byte, and every inbound media key was
discarded. Same failure shape as the member id: silent, total, and reported by
nothing.

`set_self_uuid` was already passing 16 bytes, from a different code path. That
divergence is what let it go unnoticed, so there is now exactly one conversion,
`sync::ringrtc_user_id`, and the member map, the sender path and this device's own
id all go through it. An architecture test enforces that: the kind-prefixed form
may only be produced in that one function, anywhere in `src/`.

It cannot prove a call works. It proves there is only one definition left to be
wrong about, which is the part that has now bitten twice.

### 2.2c The third bug: the microphone was never opened

Not a byte-length bug, but found the same way: by asking what the log could still
not explain once the first two were fixed.

With `keys=1` and audio audible inbound, the remaining symptom was that nothing we
sent could be heard. Every outward signal said otherwise — `state: Connected`,
`audio muted=false`, a media key sent to the right recipient, heartbeats
broadcast — and none of them is capable of detecting this, because none of them
touches the audio device.

`audio_device_module.rs` never opens the input on its own. `init_recording` is
called from `set_audio_warmup` and from `update_recording_device` — and the latter
only does so `if was_initialized`, which it cannot be the first time:

```rust
let was_initialized = self.input_stream.is_some();
…
if was_initialized { self.init_recording()?; }
```

So the first initialisation has to come from `set_audio_warmup`, which this client
never called. `start_recording` then refuses outright:

```
Cannot start recording without an input stream -- did you forget init_recording?
```

and the outgoing track carries nothing. **Incoming audio is initialised on a
separate path, so the client received perfectly and transmitted silence** — which is
exactly what was observed, and exactly why it was so confusing: one direction
working is strong evidence the media stack is fine, and it is.

RingRTC logs a warning through a logger this build does not surface, so the failure
was invisible.

Signal's own clients call the equivalent (`RingRTC.setMicrophoneWarmupEnabled`)
before connecting a call. `PeerConnectionFactory::set_audio_warmup` is already
public but unreachable — the factory is a private field of `NativePlatform` — so
this needs a three-line vendor patch, documented in
`vendor/ringrtc/CHANGELOG-VENDOR.md` §2. There is no host-side workaround: the
device module is reachable only through the factory, and the one function that
opens the input is called from nowhere else in the crate.

The microphone is now opened on both call paths and closed on every teardown path,
because a microphone left open after a call ends is a privacy problem rather than a
resource one.

Note this is **not** the same as unmuting, and neither substitutes for the other.
The mute flag is what the rest of the call is told; the warmup is whether the
device is open. A client can be unmuted and transmitting nothing, and the reverse
is equally possible.

### 2.3 Observer surface

| RingRTC event | Signal | This client | Status |
|---|---|---|---|
| Connection state changed | `onLocalDeviceStateChanged` | logged, drives banner phase | match |
| Join state changed | same | logged, drives banner phase | match |
| Remote device states changed | `onRemoteDeviceStatesChanged` | logged, drives the audio claim | match |
| Audio levels | `onAudioLevels` | logged only | match, inert — see below |
| Peek changed | `onPeekChanged` | HTTP peek logged | diverge |
| Peek result | — | handled but **unreachable** | dead code |
| Ring | `onGroupCallRingUpdate` | handled | match |
| Ended | `onEnded` | handled, drives banner | match |
| Reactions, raised hands, speech, remote mute | handled | handled, not surfaced | match |
| RTC stats report | consumed for call history | logged | match |

**Audio levels are inert in this build.** `get_audio_levels` is a real FFI call and
the native WebRTC layer returns zero for both the captured and received levels, so
a zero level cannot be distinguished from a missing measurement. The same is true
of `RtcStatsReportComplete`, which never fires. Consequently the banner's audio
state is driven by per-device evidence instead, and claims nothing it cannot
support. Worth raising upstream or resolving by vendoring the native side.

**`GroupUpdate::PeekResult` is unreachable.** It is emitted only from the
`sfu::Delegate` path, while the peeks actually being issued come from the group
call's own `sfu_client.peek(...)`. The arm is correct but never fires; the HTTP
peek is the real signal and is where the participant counts come from.

### 2.4 After joining

| Step | Signal | This client | Status |
|---|---|---|---|
| Announce the call to the group with its `eraId` | `GroupCallUpdate` on join/leave | — | **missing** |
| Peek before joining, for a lobby | `peekGroupCall()` | joins blind | **missing** |
| Show participant count / capacity before joining | `maxDevices`, pending clients | — | **missing** |
| Named participant roster in the UI | `GroupCallRemoteParticipantType` | names, mute state, presenting, video | match |
| Full call screen | `CallScreen.dom.tsx` | a banner | **missing** |
| Record group calls in history | yes | 1:1 only | **missing** |

The missing announcement is the most consequential of these. Signal sends a
`GroupCallUpdate` carrying the call's `eraId` when the local device reaches
`Joined`, and that is how other members' devices learn a call is happening. This
client only ever *receives* rings, so a member who is not ringing us has no way
to know the call exists.

### 2.5 Devices and audio routing

| Step | Signal | This client | Status |
|---|---|---|---|
| Select an input | via `setPreferredDevice` | once at init, 5s deadline | diverge |
| Re-run device selection on a timer | `#startDeviceReselectionTimer` | — | missing |
| Speaker toggle | route picker | switches the **system default** CoreAudio output | diverge, deliberate |
| Mirror the OS microphone mute | `muteStateChange` subscription | — | **missing** |
| Microphone warmup | `setMicrophoneWarmupEnabled` | — | missing |

The missing system-mute mirror is a plausible explanation for a report of "the
mic is muted and I did nothing": a hardware or keyboard-level mic mute would
present here as a call that is mysteriously muted, because nothing observes the
system state.

### 2.6 1:1 calls, for completeness

The 1:1 path is verified working with two real clients. Two things are not honest
about themselves:

- **1:1 "Start Video" is a local flag with no media behind it.**
  `CallController.setLocalVideoEnabled` only assigns to a struct and never reaches
  the core. There is no camera code in `CallController` at all. A control that
  changes an icon and nothing else is worse than no control.
- **ICE uses public STUN only.** Signal fetches authenticated TURN from
  `v2/calling/relays` on the authenticated chat service. A group call does not
  need it — RingRTC hardcodes an empty ICE server list for group calls and gets
  its configuration from the SFU join response — so this is a 1:1 concern only,
  and matters on restrictive networks.

---

## 3. Deliberate divergences

Recorded so they are not rediscovered as bugs.

| Divergence | Why |
|---|---|
| Speaker toggle switches the **system default** CoreAudio output device | Simpler, and the flag only flips after the change is confirmed. A per-call device is better but needs a device-picker that does not exist yet. |
| A denied microphone permission cancels the call | Arguably safer than Signal's behaviour of joining anyway: a call that joined with no microphone is, to everyone else, a broken client. But it is a real divergence. |
| Group ids are derived from the master key rather than read from the conversation | The conversation object does not exist in this client; the master key is the equivalent. |
| Group client lookup is not cached | Correctness over speed. |
| Banner rather than a call screen for group calls | A screen was never built. The banner is not a substitute and should not be presented as one. |
| Two-member group calls take RingRTC's targeted send path | RingRTC's own choice. A two-person call legitimately has one recipient. |

---

## 4. Work list

Ordered. Each item states what "done" means, because most of these can be made to
look finished without being finished.

### A. Verify the audio fix

Everything else is downstream of this and none of it is worth building until it
is confirmed.

- [x] **A1. Media keys arrive.** `group devices … n=1 keys=1`. Confirmed
      2026-09-26. This unblocked the receive direction, and audio is heard.
- [x] **A2. Inbound audio is heard.** Confirmed against a real second client.
- [ ] **A3. Confirm the microphone fix — the last leg.** `[core] microphone warmup
      enabled=true`, then speak and have the other side confirm. *Done when:*
      they say they can hear us. This is the only remaining audio fault known.
- [ ] **A4. Both directions in one call.** Once A3 passes, confirm a single call
      carries audio both ways for more than a few seconds, with no dropped frames
      at either end.
- [ ] **A5. `unmuted` flickers between 0 and 1** in `group devices` even while
      audio flows. Their heartbeat is arriving but its mute field is not yet
      understood. Not blocking audio, and not yet explained — instrument before
      theorising.

### B. Correctness

- [ ] **B1. Announce the call on join and leave.** Send a `GroupCallUpdate`
      carrying the call's `eraId` when the local device reaches `Joined`, and
      again on leave. *Done when:* a member who is not ringing sees the call
      exist. This is the single largest functional gap.
- [ ] **B2. Observe the system microphone mute.** Mirror the OS mute state into
      every live call, as Signal does. *Done when:* engaging the hardware mic
      mute mutes a live call with no user action in the app.
- [ ] **B3. Make the sync loop reconnect.** When the message stream ends it
      `break`s and clears the loop controller, after which every later request —
      SFU included — fails with "sync loop is gone". Observed killing a live call
      12 s in. *Done when:* a call survives a stream interruption.
- [ ] **B4. Cancel a declined ring.** A decline currently sends nothing; the
      ringer's `ring_id` has to be echoed back.
- [ ] **B5. Guard the resolver against a poisoned lock.** The opaque-id set is
      read under a mutex that can only fail if a test panics mid-hold; decide
      whether a poisoned lock should be recovered from or surfaced.

### C. Video and screen sharing

Ordered by dependency. **None of this is started**, and the honest position is that
C2 is the gate on all of it.

- [ ] **C1. Stop 1:1 video pretending.** Either wire `setLocalVideoEnabled` to the
      core or remove the control. Cheapest item here and the only one that is
      purely a matter of not lying. *Done when:* no control in the app claims a
      capability the app does not have.
- [ ] **C2. A real incoming `VideoSink`. `NativeCallContext` is given a
      `NullVideoSink`, so every decoded remote frame is discarded — screen share
      included, since it arrives as video.** This is the gate: receiving video and
      receiving a screen share are the same work, and neither can start until there
      is somewhere to put frames.
      *What it involves:* a `VideoSink` implementation that receives
      `VideoFrame`s, a CoreMedia/VideoToolbox path to get them on screen, and the
      native callback wiring to deliver them across the FFI boundary. This is
      native interop, not Swift.
      *Done when:* a remote participant's video and a shared screen both appear.
- [ ] **C3. Bind the outgoing video source to the camera.** Created and left
      alone. Camera permission is already requested correctly — only on demand,
      and a refusal leaves the camera off without ending the call — so the
      permission half is done and the capture half is not.
- [ ] **C4. A local preview.** Needed before a group call screen is meaningful.
- [ ] **C5. Screen share as a distinct mode.** Presenting and screen sharing are
      separate fields in the SFU heartbeat and are not the same thing: a share is
      usually 30fps with no audio, a camera is the opposite. RingRTC already
      negotiates them separately, so the host has to as well.
- [ ] **C6. Video requests.** The SFU only forwards video once asked, and RingRTC
      drives that from the peer's height. It should follow automatically once C2
      works, but it is unverified and belongs on the list rather than assumed.

### D. Group call experience

- [ ] **D1. Peek before joining.** Fetch a proof and peek without connecting, so
      the lobby can show the participant count, whether the call is full
      (`maxDevices`), and whether joining is possible at all.
- [ ] **D2. A group call screen.** 1:1 has one; groups have a banner. Reuse
      `CallControlsBar`.
- [x] **D3. Named participants.** The banner lists everyone RingRTC has resolved,
      each with their own mute state, whether they are presenting or sharing their
      screen, and whether they have been heard. A participant with no media key
      says so, because they cannot be heard and that is otherwise invisible.
- [ ] **D4. Group calls in history.** 1:1 only today.
- [ ] **D5. Device reselection timer.** Re-run selection so a headset plugged in
      mid-call is picked up.

### E. Shipping

- [ ] **E1. Packaging and signing.** Currently an ad-hoc signature, which changes
      every rebuild, so the Keychain prompt reappears each build.
- [ ] **E2. Verify Keychain behaviour in a signed app.** Untested.
- [ ] **E3. Clean install and upgrade paths.** Untested.
- [ ] **E4. Real two-client verification matrix.** Run it and record it.
- [ ] **E5. Authenticated TURN for 1:1.** `v2/calling/relays` on the authenticated
      chat service. Group calls do not need it.
- [ ] **E6. Find the `swift test` teardown segfault.** Roughly 1 run in 4, after
      every test has passed. Pre-existing — reproduced at `e2608cb` with later
      work stashed. Harmless to the results, but it hides real failures.

### F. Deferred, recorded so they are not lost

- [ ] **F1. CallKit**, lock-screen actions, multi-call handling.
- [ ] **F2. APNs/PushKit**, launch-at-login, killed-app call delivery.
- [ ] **F3. Ringtone and ringback audio**, full system audio-route selection.
- [ ] **F4. Call links** (`RingRTC.getCallLinkCall`). Same abstraction, different
      authentication and a room id instead of a group.
- [ ] **F5. Ad-hoc "group rings"** (`ring_intention`) are refused; they need a
      separate path.
- [ ] **F6. Urgent-message flag** on the call sender, which Signal sets.
- [ ] **F7. Microphone warmup**, as Signal does before joining.

---

## 5. What is deliberately not being done

- **Vendoring the native RingRTC C++/WebRTC side.** Would fix the inert audio
  levels and the absent RTC stats, at the cost of owning a large native build.
  Raise upstream first.
- **Reimplementing group membership proof.** It works, and it is real: the
  credential is server-issued and cannot be fabricated.
- **Routing group call data through the chat path.** Would reintroduce the
  empty-control-envelope and group-routing class of bugs.
- **Synthesising anything to make a call appear to work.** A call that cannot be
  placed must not be presented as placeable, and a measurement that was not taken
  must not be reported as one.
