# Native call implementation status (RingRTC, macOS)

_Last updated: 2026-09-24_

## Goal and scope

Cuztom Signal uses native RingRTC/WebRTC for calls. There is no `signal-cli`
subprocess and no virtual-audio-device bridge.

The supported release scope is **native 1:1 voice calling**. Group calls are
intentionally disabled until Signal membership proofs, group/member identity
derivation, SFU HTTP support, and opaque group signaling are implemented.

## Completed foundation

- `ringrtc` builds with `native` and `prebuilt_webrtc` features.
- The macOS RingRTC build uses `rust-core/scripts/grealpath` to provide the
  GNU-compatible `realpath -e` behavior required by RingRTC's build script.
- The dylib links the required CoreAudio/AudioToolbox/AVFoundation pieces.
- `sync::call_signal_part` lifts `CallMessage` envelopes out of the normal
  chat receive path, including ICE updates.
- Empty DataMessage control envelopes, including group-call updates, are
  filtered before roster/history rows are created. They no longer appear as
  blank messages with sender chips.

## Completed 1:1 path

### Rust/RingRTC

- Native `PeerConnectionFactory` and audio device initialization.
- Signal `CallMessage` offer/answer/ICE/hangup/busy signaling.
- Persistent bridge between RingRTC callbacks and the Rust worker loop.
- RingRTC `message_sent` / `message_send_failure` handling.
- ACI/PNI identity-key lookup from the protocol store.
- Native call start/accept/hangup C ABI commands.
- Legacy raw-SDP commands fail explicitly rather than pretending to work.

### Swift/macOS

- `RustCoreService` resolves the native symbols.
- `CallController` maps native signaling and state into a deterministic UI
  state machine.
- Incoming race handling for an offer that arrives before native `connected`.
- Incoming/outgoing/connecting/active/ended overlays.
- Mute, hangup, microphone permission, and elapsed connected time.
- Friendly caller names and Note to Self/You identity handling.
- Incoming-call local notification, deduplicated by call record and cancelled
  on answer/decline/hangup.

## Verification

- `cargo check`: passed.
- `cargo test --lib`: 6 tests passed.
- `cargo build --release`: passed.
- `swift build --product CuztomSignal`: passed with full Xcode.
- `swift test`: 38 tests passed.
- Fresh app/link smoke test reached linked sync and initialized native
  RingRTC.
- Two-client 1:1 voice call with microphone capture was manually verified.

## Group-call blocker

The group-call button remains disabled. **Research update 2026-09-25:** the
membership proof — previously assumed to require an unimplemented calling
server — is in fact obtainable. Traced from the installed Signal Desktop
8.28.0 bundle (`app.asar` → `bundles/preload/main.js`):

1. Fetch ZK group credentials:
   `GET {chatService}/v1/certificate/auth/group?redemptionStartSeconds=<s>&redemptionEndSeconds=<s>&zkcCredential=true`
2. Build the ZK presentation locally:
   `AuthCredentialWithPniZkc::present(server_params, group_secret_params, randomness)`
3. Redeem it for a call token at the CDN:
   `GET {cdn}/v2/groups/token` with
   `Authorization: Basic base64(hex(groupPublicParamsHex + ":" + presentationHex))`
   and `Content-Type: application/x-protobuf`
4. Response is `ExternalGroupCredential { string token = 1 }` (already present in
   `protobuf/Groups.proto`)
5. Hand the token to RingRTC via `set_membership_proof`

All cryptographic primitives already exist in the vendored crates
(`zkgroup::AuthCredentialWithPniZkc::present`, `GroupSecretParams::get_group_identifier`,
`GroupSecretParams::encrypt_service_id`). The remaining work is wiring:

1. An authenticated chat-service GET for `/v1/certificate/auth/group`, and a
   way to read today's credential out of presage (its `groups_manager()` is
   private, so this may need a presage patch or a self-fetch).
2. A CDN GET with ZK basic auth for `/v2/groups/token`.
3. RingRTC group-ID/member derivation, the HTTP delegate, and SFU response FFI.
4. Opaque group-call signaling transport over `CallMessage.opaque`.
5. Group-call FFI commands and Swift lifecycle/UI.
6. Two linked/native-client interoperability testing.

Also discovered: `getIceServers` maps to `v2/calling/relays`, Signal's
authenticated TURN relay list. Fetching it would replace the public-STUN-only
ICE configuration currently used for 1:1 calls.

Do not route group-call data through the normal `DataMessage` chat path; doing
so would reintroduce the empty-control-envelope and group-routing class of
bugs.

## Feasibility verification 2026-09-25

Checked against the pinned dependency checkouts before committing to an
approach. Results:

- **`signal-cli` is not an option.** Its man page has no calling support of any
  kind (no `call`, `startCall`, `mute`, or `joinCall` command). It is also a
  Java project requiring JRE 25, licensed GPL-3.0. Messaging and group
  administration only.
- **Signal Desktop cannot be wrapped.** Its calling stack is a Node N-API addon
  (`@signalapp/ringrtc` → `libringrtc-arm64.node`) plus app-internal
  TypeScript. That addon is a packaging of the same `signalapp/ringrtc` crate we
  already compile in, plus a N-API host and JS runtime we would have to embed.
- **The credentials are not currently reachable, but only one patch away.**
  presage never handles group credentials (no reference to them anywhere), and
  `groups_manager()` is private and creates a fresh `InMemoryCredentialsCache`
  per call, so nothing is cached. However `AccountManager` and
  `PushService::request` already provide a generic *authenticated* chat-service
  request, and presage constructs that service itself
  (`self.identified_push_service()`). So one small `pub async fn` added to
  presage is sufficient to issue
  `GET /v1/certificate/auth/group?...&zkcCredential=true`.
  `reqwest::RequestBuilder` is returned, so no new dependency is needed.
  `service_error_for_status` is `pub(crate)`, so the status check is done
  locally.

## Hybrid implementation plan

The split follows where the constraints actually fall. ZK group cryptography
and Signal account auth cannot be done in Swift, so they stay in Rust; the CDN
hop and all lifecycle/UI work are better in Swift.

| # | Increment | Where | Independently verifiable? | Status |
|---|---|---|---|---|
| 1 | Group id + member identities + proof auth string | Rust | **Done** — 6 offline tests | ✅ |
| 2 | Authenticated credential fetch | presage patch → Rust FFI | Vendored presage | **Done** — 12 Rust + 6 Swift tests |
| 3 | CDN token fetch (`GET /v2/groups/token`) | Swift | Mock transport | **Done** — 13 tests | ✅ |
| 4 | SFU request/response bridge | Rust + Swift | Injected synthetic response | **Done** — ABI 3, 6 tests | ✅ |
| 5 | Group-call lifecycle + signaling transport | Rust | Fake SFU client | **Code complete** | ✅ |
| 6 | `GroupCallController` + UI | Swift | Against the fake bridge | **Code complete** — 25 tests | ✅ |
| 7 | Real two-client verification | On device | A second Signal client | **Not started** | ⬜ |

Increments 3 and 4 come early on purpose: a wrong basic-auth header or a
stalled SFU request is invisible until a real call connects, so both are the
pieces most worth proving with tests before anything is built on top of them.

### ABI 4

ABI 3 added `core_cmd_http_response`, the SFU request/response bridge. ABI 4
adds what a group call needs to actually join:

| Symbol | Why |
|---|---|
| `core_cmd_group_call_proof_authorization` | Fetches the ZK credential and presents it in one hop. Without a real credential there is no proof, and the join is refused. |
| `core_cmd_group_call_group_id` | The ZK identifier a room is keyed on, derived from the master key a group thread id is built of. Without it a group call cannot be started. |
| `core_cmd_group_call_member_identities` | The roster the SFU needs to map opaque participant ids back to people. |
| `core_cmd_group_roster` | A group's title and member ACIs, which the roster is built from. |
| `core_cmd_group_id_map` | Maps an inbound group id back to a group on this device, deciding which calls are receivable at all. |

Older dylibs lack these symbols, so the Swift loader rejects them at
`core_abi_version` instead of loading a core that would fail later with a
misleading error. A pre-ABI-4 bundle therefore fails loudly at startup rather
than hanging on join.

### ABI 5

| Symbol | Why |
|---|---|
| `core_cmd_sfu_http_request` | Performs the SFU's own HTTP requests. RingRTC will not do it itself — it raises them and stalls — and a host HTTP client cannot reach any Signal service host, because they serve Signal's own CA rather than the system roots. Without this, every SFU request fails at the TLS layer and the join cannot proceed at all. |

Without it, `URLSession` was asked to talk to `sfu.voip.signal.org` and failed
with no status, which reached the user as "the call could not be completed". A
dylib without this symbol is rejected at load, not discovered mid-call.

### Increment 6: complete

`GroupCallController` owns the sequence, which is the only part where a bug can
leave a call silently half-connected:

1. `join` raises `request_membership_proof` and **blocks** the SFU join until a
   proof is presented.
2. The proof is a ZK credential, so it cannot be fabricated. No credential means
   the call fails; it never joins "unverified" and never reports success.
3. `request_group_members` supplies the roster, without which a call connects
   but nobody is identifiable.
4. The SFU's HTTP requests are answered by request id, including on failure, or
   RingRTC stalls forever.

Three findings worth keeping:

- **RingRTC does not create a group client from inbound signaling.** It routes a
  message to an existing active client and otherwise drops it with "unknown
  group ID". A host therefore cannot receive a group call it has not already
  joined, and the group has to be read out of the payload
  (`group_call_message.group_id`) before a client exists. That is why the inbound
  event carries `group_id`.
- **The credential is bound to the exact redemption instant.** The offline
  round-trip test caught this: converting the REST milliseconds to zkgroup's
  seconds must not lose anything, so a sub-second remainder is refused with its
  own error rather than rounded into a credential that fails to verify and
  reports as an unrelated rejection.
- **State names must be matched whole.** RingRTC's are `NotConnected`,
  `Connecting`, `Connected`, `Reconnecting`, so a `contains("connected")` test
  reads three of the four as connected. The mapping is pinned per state.

Inbound calls for a group this device is not in are not joined: a call for such a
group is not receivable, and guessing would create a client for a room that
cannot exist.

### Increment 5: complete

The membership-proof trigger, member framing, the lifecycle
(`start_group_call`, `join`, `leave`, `end`), and both signaling directions are
implemented. Group clients are torn down on logout, relink, and reset so no SFU
or media state survives into a new account.

- **Outbound**: RingRTC's bytes are wrapped in the Signal `CallMessage.opaque`
  carrier (field 10) and fanned out with presage's `send_message_to_group`.
  RingRTC names a group by its 32-byte ZK identifier while the store is keyed by
  master key, so each signal derives every local group's identifier to find the
  match. Nothing is cached: a stale entry could only fail a send, but not
  caching removes the question entirely.
- **Inbound**: `call_signal_part` recognises an opaque-only `CallMessage` and
  emits a distinct `group_call_signal` event, so a group message can never be
  read as 1:1 signaling or as a chat row. The raw bytes go to
  `CallManager::received_call_message` and RingRTC parses the group id itself.
- Group signals share the 1:1 signal queue, so ordering, backpressure, and the
  session-generation fence all apply unchanged.
- `recipients_override` is deliberately ignored: Signal group call signaling is
  group-wide and RingRTC's own crypto already scopes the payload.
- Ad-hoc "group rings" remain refused. They need the ZK group send-token flow,
  which is a different protocol from Signal group calls.

### Open decision: how to carry the presage patch

**Resolved: presage is vendored** under `rust-core/vendor/presage` and both
`presage` and `presage-store-sqlite` are pointed at the local tree. Both are
required together: `presage-store-sqlite` depends on `presage` by relative path
inside the upstream workspace, so patching only one would put two copies of the
crate in the graph.

The patch is one new `pub async fn` on `Registered` that issues the
authenticated credential GET, plus one dependency edge that already existed
transitively. The response is returned as raw JSON and decoded in this crate
where the shape is tested. See `rust-core/vendor/README.md` and
`rust-core/vendor/presage/CHANGELOG-VENDOR.md` for the exact change and how to
re-apply it after an upstream update.

## Known call limitations and follow-ups

- **A group call rings.** The ring is a `ring_intention`, and it is the *only*
  thing that can ring a device — the media key RingRTC produces on its own needs
  the other members' demux ids, which only exist once a call is under way, so it
  cannot be what starts one. RingRTC's `start_group_ring` is private and
  `CallManager` exposes no way to send one, so the host sends it. Three things
  were wrong and all three had to be fixed:
  - The ring was never sent. Now `ring_group` sends a `ring_intention` (plus the
    `group_call_message` announcement, which is a different signal: the ring is
    what a device acts on, the announcement is what a client already in the call
    routes).
  - The group id was read only from `group_call_message`, so a `ring_intention` —
    which names its group in its own field and has no `group_call_message` at
    all — read as naming none. That is why inbound was silent while the payloads
    were arriving. All three carriers are read now.
  - `GroupUpdate::Ring` fell into the handler's catch-all and was dropped.
    RingRTC validates the ring, tracks it, and reports the outcome; that outcome
    was being discarded one layer above the host. And on the Swift side the ring
    was handled *after* the "does this controller own this client" guard, which a
    ring can never pass, because a ring has no client behind it.
  Only `Requested` becomes an incoming call; busy, expired, and accepted-elsewhere
  are outcomes, and showing one as an incoming call would be a call that does not
  exist. A ring that *is* requested now shows a banner with Join and Decline, and
  answering resolves the group from the ring — the only place a group is named
  before anyone has joined — and then runs the ordinary join. Declining is local:
  a cancellation has to echo the ringer's `ring_id` back in a message this client
  does not send, so declining does not pretend to cancel anything.
- **An inbound signal prepares a client; it does not join the call.** A client has
  to exist for RingRTC to route signaling to it, so one is created — but joining
  is the user's decision. It used to join, which is what made an incoming call
  *look* like a call: the SFU admitted the client, so the app sat saying "Joining
  the call…" for a call nobody had answered and that could only be left by ending
  it. The banner was then invisible because a call was already showing, so it
  appeared only once the call was ended. It also made answering fail, since
  RingRTC refuses a second active client for a group as `Client already exists for
  call`; the prepared client is now kept and reused, and released on reset so it
  cannot hold the group occupied.
  (`anInboundSignalPreparesAClientWithoutJoining`,
  `aPreparedButUnansweredClientIsReleasedOnReset`)
- **An incoming ring must be announced, not merely stored.** The controller is a
  Combine `ObservableObject`; the host model is Swift `@Observable`. A computed
  property reading `incoming` across that boundary registers no observation
  dependency, so the ring arrived, `incoming` was set, and the banner never
  appeared — the view was never told to re-read. Both halves were correct and the
  UI still never updated, which is only fixable if the change is announced.
  `setIncoming` is now the single place it changes and notifies
  (`aChangeToTheIncomingRingIsAnnounced`).
- **Every call path primes its own roster.** The roster is the member map the SFU
  needs in order to attribute this client and to encrypt media towards anyone.
  It used to be primed by the host before calling in, which meant the
  answered-ring path — added later — silently missed it. A call joined against a
  cache that was never filled hands the SFU no member map: it connects, nobody
  can be attributed, and **peers report this client as malfunctioning**. Observed
  as `members-built count=0` on two of three calls, where the third had
  `count=2`. The requirement is now on `GroupRosterProviding` itself, with a
  default that reads the cache, so a path cannot forget it.
  (`everyCallPathPrimesTheRosterItself`)
- **The sync loop does not reconnect.** When the message stream ends, the loop
  `break`s, `set_sync_ctrl(None)` runs, and the loop is gone for good until the
  account is relinked. Everything routed through it then fails with "sync loop is
  gone" — including **every SFU request**, because the SFU path uses the live
  manager by way of the same control channel. Observed killing a live call 12
  seconds in. A linked client that never reconnects is not really linked, and this
  is the next thing to fix.
- ICE currently uses public STUN servers. Signal's authenticated TURN relay
  list is not fetched yet, which is a real limit on 1:1 connectivity between
  restrictive networks. **This does not apply to group calls** — RingRTC's group
  path hardcodes an empty ICE server list and takes its configuration from the
  SFU's own join response, so a group call's media path is the SFU's choice, not
  ours. Verified from RingRTC `group_call.rs:1374` and from Signal Desktop's log,
  where `v2/calling/relays` appears under a 1:1 call.
- **Inbound group call signaling is delivered once, natively.** The native side
  hands every inbound payload to the live RingRTC client *before* the host event
  exists. The host used to treat that event as a new call to join, so every
  payload tore the live call down and rebuilt it — and for an established call
  inbound signaling is routine, so a connected call never stopped resetting
  itself. It presented as a client id climbing through a dozen values, each
  re-running the whole join, and finally `Client already exists for call` as one
  rebuild raced its predecessor. **A payload for the group already in progress is
  now ignored; only a different group replaces the live call.**
  Covered by `signalingForTheLiveCallDoesNotRestartIt` (verified to fail against
  the old behaviour), `signalingForADifferentGroupReplacesTheLiveCall`, and
  `aPayloadWithNoGroupIDIsNotAFailureWhileACallIsLive`.
- The current sender does not expose Signal's urgent-message flag, so a call to
  a fully offline phone may not produce a push notification.
- Ringtone/ringback audio and full system audio-route selection are not
  implemented.
- Video calling is not enabled in the production UI; the current supported
  call mode is voice. Group calls are likewise voice-only in the UI.
- Group call participants are shown as a count, not a named roster. The SFU
  supplies participant ids rather than names, and mapping them needs a
  per-participant profile key exchange that is not implemented. Speaking
  indicators and reactions are received but not surfaced for the same reason.
- Ad-hoc "group rings" (RingRTC's `ring_intention` path) are refused. They need
  the ZK group send-token flow, which is a different protocol from Signal group
  calls.
- CallKit, lock-screen call actions, multi-call handling, and persistent call
  history remain future work. Only one call is live at a time; starting a second
  is refused rather than silently replacing the first.
- APNs/PushKit, launch-at-login, and killed-app call delivery require a
  separate signed provider/APNs path and are not implemented.

## Serving-side rejections and how to read them

A group-call join is refused by something other than this client more often
than it is refused by a bug here, and the two look alike from outside. What was
actually happening, and what identifies it next time:

| Symptom | Means | Check |
| --- | --- | --- |
| `403` from a CDN for the group token | wrong host — the token is a **storage**-service route (`v2/groups/token`), not a CDN one | endpoint host in the request |
| `400` with an **nginx HTML body**, no JSON | nginx rejected the request before the app. Duplicate `Authorization` headers are the known cause: `RequestBuilder::header` appends, so a proof added on top of the account's own `Authorization` yields two, and nginx 400s regardless of total size | `HttpAuthOverride::Unidentified` in `group_call_token` |
| `401 Credentials are required…` (plain text) | reached the app; the credential was not accepted. This is the *normal* response to a placeholder or malformed proof, and the control every other observation is compared against | — |
| `400` with a JSON body | the app parsed the request and rejected a parameter | the body, which is logged for non-2xx |
| `200` that will not decode | the credential *was* issued; only the response envelope is unexpected. `Content-Type` and the first four body bytes are logged, which separates protobuf (`0a ..`) from JSON (`7b 22 ..`) from gzip (`1f 8b`) | `decoded as protobuf` / `decoded as JSON, keys=[..]` / `matched neither` |
| `sfu request … failed` with **no status** | the request was never performed. Every Signal service host is a case like this, and a host HTTP client cannot reach any of them | `sfu request transport failure:` on the Rust side |

The distinction that cost the most time: a bare nginx `400` HTML page is not the
application saying the parameters are wrong. It says the request never got
there. `group_auth_credentials_raw` worked at the same moment `group_call_token`
did not, from the same client, on the same day — the difference was that only the
latter added a second `Authorization` header.

The same reasoning applies to a `2xx` that will not decode. A `200` is not
evidence that the body is the message expected, and it is not evidence that a
token was issued. Both are claimed only once the body is parsed, and the format
is logged so a mismatch names itself.

- **Every group call asks for the microphone before the client is created.** The
  1:1 path has always done this; the group path did not, so a group call joined
  the SFU with **no microphone access at all** — no prompt, no audio, and peers
  reporting "can't receive audio and video from this client". Every step of the
  call succeeded and the one that carries a voice did not happen.
  `NSMicrophoneUsageDescription` was present in the bundle the whole time, so the
  app declared the intent and simply never asked.
  Asked *before* the client is created, not at first capture: RingRTC disables
  recording while it believes it is alone in the call
  (`set_audio_recording_enabled(false)`), so capture may not begin until long
  after a prompt would be useful, and a permission never asked for is a
  permission never granted. A denial refuses the call rather than joining
  silently, and on the answer path the ring is *kept* so it can be retried after
  the user grants access — clearing the banner and leaving the reason only in the
  log is the worst of the three outcomes.
  (`everyGroupCallAsksForTheMicrophoneFirst`,
  `aDeniedMicrophoneStopsTheCallInsteadOfJoiningSilently`)

- **A group call's media keys are sent to the named recipients.** This was why
  there was no audio, and the symptom is the interesting part: the peer reported
  "can't receive audio and video" **only once somebody spoke**. RingRTC sends a
  group's media keys to specific recipients and only uses the group-wide route
  when there is more than one of them:

  ```rust
  (SignalGroup, _) if recipients.len() > 1 => send_signaling_message_to_group(…)  // supported
  _ => for recipient in recipients { send_signaling_message(recipient, …) }       // was refused
  ```

  A two-person call has exactly one recipient, so it took the second branch — and
  `send_call_message` returned `Err("targeted group call send is not supported")`.
  The peer therefore never received the key needed to decrypt this client's audio.
  Nothing is wrong while nobody talks, because there are no frames to decrypt, so
  the fault is invisible until the first word. The refusal was deliberate ("safer
  than guessing a recipient") and wrong: the recipient is supplied, not guessed.
  (`a_targeted_group_signal_is_carried_in_the_same_opaque_envelope`,
  `a_ringrtc_recipient_id_becomes_the_thread_it_is_addressed_by`)

- **A group call says whether its microphone is muted.** RingRTC starts a group
  call with `outgoing_heartbeat_state.audio_muted: None` and reads that as
  **muted**:

  ```rust
  !state.outgoing_heartbeat_state.audio_muted.unwrap_or(true)   // None ⇒ muted
  ```

  Nothing in the call path ever said otherwise, so the heartbeat broadcast to the
  other members reported this client as having its microphone off, and its own
  speaking detection treated it as silent. A peer reported exactly that — "mic and
  camera turned off" — alongside "can't receive audio and video".
  `CallManager::set_outgoing_audio_muted` already existed; the host simply never
  called it. It is now called on both entry points, before the join, so the very
  first heartbeat already says the microphone is live. The default is fail-closed,
  which is the right default and the wrong one for a host that has already asked
  the user and been told yes.
  (`everyGroupCallSaysItsMicrophoneIsLive`)

## Why two-party audio is silent, and why nothing said so

The join chain is verified end to end and audio is still silent in **both**
directions, with no error anywhere. The reason is that RingRTC treats "I am the
only participant" as a reason to turn the whole media path off, and it decides
that from a number we never had visibility into.

`group_call.rs:3470` computes the send rates from the count of **other**
participants in the SFU peek:

```rust
if local_device_is_participant {
    let send_rates = Self::compute_send_rates(new_demux_ids.len(), …);
    Self::set_send_rates_inner(state, send_rates);
}
```

and `compute_send_rates(0, _)` returns `ALL_ALONE_MAX_SEND_RATE` (1 kbps), which
`set_send_rates_inner` turns into all of the following **at once**
(`group_call.rs:2420`):

```rust
state.peer_connection.set_audio_recording_enabled(false);
state.peer_connection.set_outgoing_media_enabled(false);
state.peer_connection.set_audio_playout_enabled(false);
```

Recording *and* playout. So a client that believes it is alone in the call cannot
send and cannot hear, while every outward signal looks healthy: the ZK proof is
redeemed, the SFU returns 200, `join: Joined`, `state: Connected` — that
`Connected` is the ICE state, and ICE genuinely does connect. Media keys go out.
The unmute goes out. And it is still silence, because the audio device was turned
off from both ends by a count nobody was reading.

RingRTC logs that decision (`"Disable audio and outgoing media because there are
no other devices."`), but only through its own logger, which this build does not
surface. The count is now read directly from the peek response and logged
(`describe_sfu_peek`, `sfu peek joined=N identified=M demux=[…]`). The peek is
JSON, not protobuf, and its participant user IDs arrive as `opaqueUserId`,
resolved against the member map supplied at join time — so `identified` below the
participant count is what tells us whether the SFU can put a name to a
participant at all, which is the same question as the `DerivedState(value=<Not
calculated>)` label a peer reported.

Nothing identifying is logged: demux ids and counts only. The opaque IDs are
per-call material and are deliberately not printed.

The next run answers one question outright: if `joined=1`, RingRTC genuinely
thinks nobody else is there, and the fault is upstream of the media path — in
whether the other participant is publishing itself to the SFU, or in the member
map arriving too late to be applied at join. If `joined=2`, the count was never
the problem and the media path is disabled for some other reason.

### Still open

- **No group call window.** The incoming banner and the in-call banner are the
  whole group call UI today; 1:1 has a call screen and groups do not. Not a bug —
  a feature that was never built.
- Declining a ring sends no cancellation (the ringer's `ring_id` is not echoed).
- The sync loop does not reconnect: when the message stream ends it breaks and
  every later request, SFU included, fails with "sync loop is gone". Observed
  killing a live call 12 s in.
- Named participants are not implemented; the roster is a count.

## What the first instrumented run actually showed

The instrumentation paid for itself. `sfu peek joined=2 identified=2` — **both
participants present, both identifiable.** The member map works, and a count of 2
means `compute_send_rates(1, _)` rather than the all-alone branch, so the send-rate
disabling is *not* the current cause of the silence. That ruled out the theory this
file was written under.

And a participant got heard, briefly, before the call collapsed. So audio does flow
— it is not fundamentally broken in either direction.

The remaining evidence says the measurement itself is missing:

```
group audio levels client=2 captured=0 remote=0 loudest=None     (× 118)
rtc stats                                                            (never)
```

`get_audio_levels` is a real FFI call into the native WebRTC layer
(`Rust_getAudioLevels`), and that layer returns zero for both the captured and the
received levels here. So `captured=0 remote=0` is the native library declining to
report, not this client failing to ask — and a zero level cannot be told apart from
no measurement. `RtcStatsReportComplete` never fired at all, for the same reason.

**Consequence for the UI:** the banner must not be driven by audio levels in this
build. Doing so left every call permanently reading "No incoming audio", which is a
confident false statement about a call that may be working. Levels are logged and
otherwise ignored.

### What the shown state is allowed to claim

Now driven by `GroupUpdate::RemoteDeviceStatesChanged`, which this build *does*
populate, and which was also being discarded:

- somebody has a `speaker_time`, so audio is genuinely being transmitted → `true`
- others are present and **not one** has sent a media key, so nothing they say
  could be decrypted → `false`
- anything else, **including a call where everyone is quiet** → nothing claimed

A quiet call is the third case. Reporting it as a fault would be the same kind of
invention as the levels were.

Logged per device as
`group devices client=2 n=1 keys=1 unmuted=1 spoke=1 video=0`, which is the first
place the four things that have to be true are visible together: their key arrived,
their heartbeat says they are unmuted, they have actually been heard speaking, and
they are forwarding video.

### The one-second window, and what it points at

The call ran 15:24:19 → 15:24:28 with two participants, then:

```
15:24:25.802  group call audio muted=false client=2
15:24:26.871  group call video muted=false client=2
15:24:28.317  sfu peek joined=1 identified=1 demux=[254417952]
```

Turning the camera on is 1.4 s before the other participant left, and the phone
reported "can't receive audio or video" as it went. The audio controls plainly
worked — the mute and unmute lines are there on the button, and the participant
count proves both sides were present. Two readings remain open and neither is yet
evidenced: the peer dropped for an unrelated reason, or unmuting video published a
stream this client cannot produce properly. The camera work below is what makes
that second reading testable.

## The silence, explained end to end

`group devices client=3 n=0 keys=0 unmuted=0 spoke=0 video=0` — RingRTC's own
remote device list is **empty**, in the same second the peek reports
`joined=2 identified=2`. Those two numbers are the whole story, and they are not in
conflict: `identified` counts the SFU having *sent* an `opaqueUserId`; RingRTC's
device list contains only the ones it can turn back into a person.

`group_call.rs:3295`:

```rust
state.remote_devices = peek_info.devices.iter()
    .filter_map(|device| {
        if device.demux_id == local_demux_id { … return None; }
        device.user_id.as_ref().map(|user_id| { … })   // <-- None drops it
    })
    .collect();
```

A participant whose `user_id` is `None` is dropped **silently**. So:

1. The SFU returns participants with obfuscated ids — `hex(sha256(GroupMemberId))`,
   where `GroupMemberId` is the member's *encrypted UID within the group*.
2. RingRTC resolves each against `hex(sha256(member_id))` for every member it was
   given by the host.
3. **No match, so `user_id` is `None`, so the participant is dropped.**
4. `remote_devices` is empty, so `new_demux_ids.len()` is `0`, so
   `compute_send_rates(0, _)` returns `ALL_ALONE_MAX_SEND_RATE`, so
   `set_audio_recording_enabled(false)`, `set_outgoing_media_enabled(false)` and
   `set_audio_playout_enabled(false)` all fire together.
5. Silence in both directions. The call joins, redeems a real ZK proof, returns
   SFU 200, connects ICE, exchanges media keys and sends heartbeats throughout.

So the original theory was right after all — the participant count *is* what
disables the audio — but the count that matters is RingRTC's **resolvable** one, not
the SFU's. The peek's `identified=2` was never evidence that anyone could be named;
it only ever meant the SFU had sent two blobs.

The same thing seen from the other side is the `DerivedState(value=<Not
calculated>)@…` label a peer reported: the SFU attributing a participant it cannot
resolve.

### The bug, found in Signal's own client

`resolved=0`, never `untried`: the roster reached RingRTC and none of it matched.
So the encrypted member ids this client computes are not the ones the SFU hashed.

Signal Desktop answers it exactly. Its group-call member list is built as:

```js
#h(e){ return Bkt(e).map(e => new F.GroupMemberInfo(t.Rr(e.aci), e.uuidCiphertext)) }
```

and the ciphertext it puts there is freshly derived from the secret params, the
same as ours — so re-encrypting was never the problem:

```js
function up(e,t){ return e.encryptServiceId(Xf(t)).serialize() }
```

Note `.serialize()`, and **nothing stripped off the front**. zkgroup's
`UuidCiphertext` is a `ReservedByte` (`VersionByte<0>`, serialized as a single
leading `0x00`) followed by two Ristretto points:

```
serialize()          len=65  first=00
serialize()[1..]     len=64      <-- what we were sending
sha256(full)     = 57b420fe…
sha256(stripped) = b6cd21b3…
```

A 64-byte value against the SFU's 65. The hashes could never agree, so no
participant ever resolved, and every step in the chain from there followed.

The comment that produced this said "zkgroup serializes a leading ReservedByte
that peers do not send". The second half of that was an assumption nobody checked,
and it was wrong: peers do send it, and Signal's own client passes the whole thing.
The length is now measured and enforced at `GROUP_MEMBER_ID_LEN` rather than left
to a comment, because a length that is wrong here yields a call that connects
perfectly and is silent, with nothing anywhere reporting a fault.

### The one measurement that settles which half is wrong

`set_group_members` now records the opaque ids its member list implies
(`hex(sha256(member_id))` per member) and the peek reader counts how many of the
SFU's ids are among them:

```
sfu peek joined=2 identified=2 resolved=1 demux=[…]
```

- `resolved=0` — our encrypted member ids are not the ones the SFU hashed. Either
  the roster is wrong, or the member list we send is not the one the SFU derives
  from the credential, and the difference has to be found in the bytes.
- `resolved=untried` — no member list reached RingRTC at all, which is a different
  fault from matching none.

Only the tally is logged. The ids are derived from group secret material and are
per-call, so they are never printed.

### Cross-checked against Signal's own source

Verified claim by claim against the repository rather than taken on trust. The
flow matches ours closely, and one hypothesis died on contact:
`enableCaptureAndSend` — the "start local media capture" step in the flow — turns
out to be **video only** (`ts/calling/VideoSupport.preload.ts`), starting the
camera and attaching the video sender. Audio capture is entirely inside RingRTC's
native layer, driven by the track created with the peer connection factory, which
is what this client already does. So there was no missing audio step here.



The asar on disk is the shipped, minified client, so it settles behaviour but not
intent. `signalapp/Signal-Desktop` confirms the same thing readably, on the actual
group-call path (`ts/services/calling.preload.ts`, `ts/util/zkgroup.node.ts`):

```ts
export function encryptServiceId(clientZkGroupCipher, serviceIdPlaintext) {
  const uuidCiphertext = clientZkGroupCipher.encryptServiceId(toServiceIdObject(serviceIdPlaintext));
  return uuidCiphertext.serialize();          // whole thing, reserved byte included
}

#getGroupCallMembers(conversationId) {
  return getMembershipList(conversationId).map(
    member => new GroupMemberInfo(uuidToBytes(member.aci), member.uuidCiphertext)
  );
}
```

Three things that came out of reading it, two of which correct earlier assumptions
here:

- **The camera is stated before the join too.** Signal calls
  `setOutgoingAudioMuted(!hasLocalAudio)` *and* `setOutgoingVideoMuted(!hasLocalVideo)`
  immediately after connect and before join. The video call was missing here. It
  happens to be the safe direction — unset reads as muted — but relying on that
  default is precisely the assumption that made the microphone wrong, so both
  flags are now stated explicitly on both paths.
- **The `setGroupMembers` ordering flagged earlier as suspicious is what Signal
  does.** It is called from exactly two places: the `requestGroupMembers` callback
  and a `groupMembersChanged` membership hook. So answering a call and supplying
  members afterwards is correct, and RingRTC re-requests once members change. That
  earlier suspicion was wrong.
- **The audio placement was right.** Both flags go in after connect and before
  join, which is what this client already did for audio.

One thing Signal has that this client does not, and that is worth knowing rather
than guessing about: it subscribes to `muteStateChange` and mirrors the *system*
microphone mute into every live call. A hardware or keyboard-level mic mute would
therefore show up as a muted call with no user action here, because nothing
observes the system state. Not yet implemented; listed below.

### Two things ruled out along the way

**The encryption is deterministic**, so re-encrypting a member's UID cannot be the
problem. `zkcredential`'s `encrypt` is `E_A1 = a1·M1; E_A2 = a2·E_A1 + M2` with no
nonce and no randomness, so the same key pair and the same attribute always produce
identical bytes.

**`GroupUpdate::PeekResult` never fires** — zero occurrences in the log. It is
emitted only from the `sfu::Delegate` path, while the peeks being issued come from
the group call's own `sfu_client.peek(...)` at `group_call.rs:1828`. So that arm
was correct but unreachable, and `RemoteDeviceStatesChanged` is the update that
actually reflects what RingRTC resolved.

## Video: what is real and what is not

Honesty first, because most of the video surface in this app is a lie today.

- **1:1 "Start Video" is a local flag with no media behind it.**
  `CallController.setLocalVideoEnabled` only assigns to `ActiveCall`; it never
  reaches the core. There is no camera code in `CallController` at all.
- **The app had no `NSCameraUsageDescription`.** Only the microphone was declared,
  so the camera could not be requested even in principle — the request fails
  outright rather than prompting. Now declared, so the prompt is *possible*; it is
  only ever requested when the user turns the camera on.
- **Incoming video renders nowhere.** `NativeCallContext` is given a
  `NullVideoSink`, so decoded remote frames are discarded. Rendering them needs a
  real sink and native interop, and that is not done.
- **A camera exists on this machine** (FaceTime HD Camera), so the hardware is not
  the limit.

What is now real: `NSCameraUsageDescription` in the bundle, a camera permission
request made **only** when the camera is turned on, and the core's
`set_outgoing_video_muted` behind the banner control.

The camera is deliberately **not** requested alongside the microphone when a call
starts. The microphone is needed for a call to be a call, so the prompt is
unavoidable there; a camera is not, and asking on every call would train the user to
dismiss it while claiming a use the call does not have. A refusal leaves the camera
off, says so, and does not end the call — a call that cannot use the camera is
still a call, unlike one that cannot use the microphone. Switching the camera *off*
never asks, so someone who never had access can always turn it off.

Still missing before video can be called working: a real incoming `VideoSink` and a
local preview, and the outgoing video source actually bound to the camera rather
than created and left alone.

## Seeing whether audio is actually arriving

"Nothing is audible" and "nothing is arriving" are different faults, and until
now this build could not tell them apart. Three signals close that gap, all of
which RingRTC was already producing and this client was discarding.

**`GroupUpdate::AudioLevels`** — per-participant audio levels, requested once a
second for the whole call via `GROUP_AUDIO_LEVELS_INTERVAL_SECS` and dropped on
the floor by the catch-all arm. A non-empty list with a non-zero level means audio
is arriving; an empty one means the SFU is delivering nothing, which is a
different problem from the SFU refusing to send. Surfaced as
`group audio levels … remote=N loudest=Some((demux, level))` and, in the UI, as
the banner's status line.

**`GroupUpdate::PeekResult`** — RingRTC's own participant count, which is the
exact input to `compute_send_rates` and therefore the exact reason audio is on or
off. Reported as `sfu peek ringrtc joined=N identified=M` so it can be compared
against the raw HTTP peek read in `describe_sfu_peek`. The two should agree; if
they do not, the disagreement is the bug.

Unlike a ring, this update carries a *request id* and no client id, so it cannot
pass the session guard that discards updates for clients this controller does not
own. It is handled ahead of that guard, for the same reason a ring is.

**`GroupUpdate::RtcStatsReportComplete`** — WebRTC's transport counters, logged as
`rtc stats bytes_in=… bytes_out=…`. Bytes arriving is the only evidence that
distinguishes "the SFU is not sending" from "it is sending and we are not
decoding it"; nothing else in a call looks different. A report with no counters is
reported as no measurement rather than as zero, because those are different
statements.

The banner distinguishes three states, not two: `Waiting for audio…` before any
level has been reported, `No incoming audio` when a level has been reported and it
was zero, and `Hearing audio` otherwise. The middle state is drawn in orange,
because a connected call with no audio otherwise looks exactly like a working
one.

### Microphone and camera in the banner

Both are in `GroupCallBanner` now, and both flip their state only after the core
confirms the change — a control that optimistically flips its own icon is the
specific failure worth preventing, because it shows a microphone as live while
the rest of the call was told the opposite. A refused change leaves the shown
state alone and logs why.

`GroupCallState` starts unmuted and camera-off, because that is what the call path
actually establishes: the join unmutes before the SFU join, and nothing opens a
camera the user did not ask for. Defaulting either the other way would have the
banner contradict the call on its first frame.

The controls only appear once the SFU has admitted the client. Before that there
is no call to be muted within, and a control that accepts a tap and does nothing
is worse than no control.

`set_outgoing_video_muted` needed no new RingRTC surface; the manager method
already existed, as `set_outgoing_audio_muted` did. What was missing was a host
that called either. ABI 7 adds the video flag, separate from the audio one rather
than a combined media flag, so toggling one never requires restating the other.

## Read receipts: a reader is not also a delivery

A member appeared under both "Seen by" and "Delivered to" in the same message
info popover. Seeing a message implies receiving it, so the two lists reported a
state that cannot exist, and every consumer of them would have had to
special-case it.

The rule now lives on the model rather than in the view, because it is a property
of the data and not of this popover:

- `recordRead(by:)` drops the member from `deliveredTo`.
- `recordDelivered(to:)` refuses to add someone already in `readBy`, so a late
  delivery receipt cannot move a member backwards.
- `enforceReceiptPrecedence()` is applied on init, after every merge, and when a
  row is read from SQLite — so messages already on disk are corrected on the next
  read instead of needing a migration.

## Where the group-call join actually stands
**A group call connects.** Verified 2026-09-25 against the real SFU,
`sfu.voip.signal.org`:

```
group token responded HTTP 200 OK, 168 bytes, content-type=application/x-protobuf, first-bytes=[0a a5 01 32]
group credential decoded as protobuf, token field 1
group call token redeemed: 165 bytes
step=proof-accepted client=1
sfu responded HTTP 200 OK, 709 bytes          ← PUT   the join
sfu responded HTTP 200 OK, 270 bytes          ← GET   the roster
state: Joined(1087663680)                     ← the SFU's room id
state: Connected                              ← WebRTC up
… then a participants poll every ~10s, each 200 …
sfu responded HTTP 404 Not Found, 0 bytes      ← the conference is gone (hangup)
```

Held the connection for 33 seconds across four successful polls. The whole chain
is real: credential, presentation, token, SFU admission, media.

| Step | Evidence |
| --- | --- |
| credential fetched | `group credential response: 4666 bytes, credentials=4, days=[20721..20724]` |
| presentation built | `presented 1461 hex chars` (97-byte public params + 633-byte presentation, matching a local probe exactly) |
| token redeemed | `group token responded HTTP 200 OK, 168 bytes, content-type=application/x-protobuf` |
| token decoded | `decoded as protobuf, token field 1` → 165 bytes |
| delivered to RingRTC | `step=proof-accepted` |
| **SFU admitted the client** | `sfu responded HTTP 200 OK, 709 bytes` on `PUT /v2/conference/participants` |
| **media connected** | `state: Connected`, held 33s |
| ended cleanly | `404` on the next poll — a conference that no longer exists, which is what a hangup looks like from the other end |

Still unverified: **two-party audio.** One client was on this machine; nobody
else was in the room. `Connected` means WebRTC came up, which is a strong
signal and not a substitute for hearing another person.

**And connecting is not the same as usable.** A later run connected repeatedly and
still did not work, for a reason entirely on the host side: every inbound signal
was restarting the call. The SFU join was never the problem by that point — see
the signaling note above. A `Connected` line in a log is evidence about one
attempt, not about a call that survives contact with other participants.

### How it got there, and what each fix was

Six failures in sequence, each looking like the last and none of them where the
log pointed:

1. `403` from a CDN — the token is a **storage**-service route, not a CDN one.
2. `400` from the storage service with an **nginx HTML body** — the request never
   reached the app. Two `Authorization` headers, because
   `RequestBuilder::header` appends and the service had already set one from the
   account credentials. RFC 9110 §11.4.1 forbids this and nginx enforces it.
3. `200` that would not decode — the body was being round-tripped through
   `String`, i.e. `from_utf8_lossy`, which rewrites every non-UTF-8 byte.
4. "the call could not be completed" on every SFU request, with no status — the
   SFU is a **third** Signal host serving Signal's own CA, and `URLSession`
   cannot reach any of them.
5. `header name: not valid UTF-8` — my own `withCString` misuse; the pointers
   dangled before the FFI ran.
6. A third Keychain passphrase read at the first SFU request — a **second native
   core**, standing up against the same database and the same global sync-control
   slot.

The recurring lesson, recorded because it cost the most: **three separate hosts
failed the same way, and twice the symptom was swallowed by a generic error
message.** A `2xx` is not evidence of a correct body, a transport failure is not
evidence the server refused, and "the call could not be completed" is not a
diagnosis. Every fix that took one run instead of several came from making the
failure say what it was.

**Two things that are not what they were assumed to be**, both corrected against
Signal Desktop 8.28.0 and its log:

- The token is redeemed at `storage.signal.org/v2/groups/token`, not a CDN.
- **ICE servers are not fetched for group calls.** `GET v2/calling/relays` is a
  1:1 thing, and Signal's log shows it under `CallingClass.handleStartCall` for
  an incoming 1:1 call. RingRTC's group call path hardcodes `let ice_servers =
  vec![];` (`group_call.rs:1374`) and takes its configuration from the SFU's own
  join response instead. So authenticated TURN is not a group-call blocker, and
  implementing it would have been wasted work. It does remain a real limit on
  1:1 connectivity.

**The SFU is reachable and its certificate is the expected one:**
`sfu.voip.signal.org` presents a Signal Messenger certificate, self-signed in
chain as `verify error:num=19`, which is why a host HTTP client must be built
with the service configuration's CA.

### The SFU's own requests are performed natively (ABI 5)

RingRTC raises SFU requests to its host and stalls until they are answered, so
the host is the only party that can perform them. It was doing so with
`URLSession`, and **every SFU request failed at the TLS layer** —
`sfu.voip.signal.org` serves a certificate from Signal's own authority rather
than the system roots, the same as `chat.signal.org` and `storage.signal.org`.

This presented as the worst kind of failure: `sfu request 0 failed: the call
could not be completed`, twice per call, with no status. The server was
reachable and the request was never sent. It is the third time the private CA
has been the cause, and the second time the symptom was swallowed by
`describe`'s generic branch.

`core_cmd_sfu_http_request` performs them natively now, on a client built with
the service configuration's certificate authority. Two things are kept
deliberately distinct:

- **A request that could not be performed is not an error.** RingRTC
  distinguishes "never happened" from "the SFU refused", so a transport failure
  is reported as a null status in the reply JSON rather than through the return
  value. Collapsing them tells RingRTC the server answered when nothing was sent.
- **Transport failures are logged with the underlying cause.** A TLS trust
  failure and a refused connection are otherwise the same opaque error, which is
  precisely what made this hard to see.

Also fixed at the source: `describe` reaching its generic branch for a
`URLError` it had no name for. The SFU path is now native, so this specific
instance is gone, but the generic fallback stays for anything unrecognised —
it is the right default for a user-facing string, and the fix is to log the real
cause alongside it, not to make the fallback more specific.

### Two bugs the first SFU request exposed

Both were mine, and both are the kind that only a live request finds.

**Dangling C pointers.** The FFI takes header names and values as arrays of
NUL-terminated C strings. The first version used `withCString` and stored the
pointers, which is the classic way to use it wrong: `withCString` guarantees its
pointer only for the duration of its own closure, so the arrays held freed memory
by the time the FFI ran. Every request failed with `header name: not valid
UTF-8` — which, ironically, was *far* more useful than the previous run's generic
message, and is why the fix was found in one iteration rather than several.

Headers now go through an owning type that allocates copies and frees them on
deinit, so they are valid for the whole call. The method and url still use
`withCString`, correctly, because the FFI call is inside those closures.

**A second native core.** `NativeHTTP` held a default-constructed
`RustCoreService`, because the public initializer had no service to take and the
app configures the bridge afterwards. The first SFU request therefore stood up a
*second* native core against the same database and the same global sync-control
slot. Its only symptom was an extra Keychain passphrase read in the log at the
moment the request was made — a `keychain op=3` line, easily skimmed past, that
should not have been there at all after startup had already read it twice.

The performer is now completed from whatever `configure` is handed, and asserted
on identity. The lesson is that the passphrase read is a useful invariant: two
reads at startup and none thereafter is the expected shape, so a third one is
evidence of a second core rather than noise.

### Superseded proof attempts must not report failure

RingRTC asks for a membership proof more than once, and a second request arrives
while the first is still inside a native call. `Task.cancel()` does not reach
`groupCallProofAuthorization` or `fetchToken` - both are foreign calls that run
to completion - so the replaced flow used to carry on and report its own
cancellation through `fail()`. `CancellationError` has no description, so it fell
through `describe`'s generic branch and produced "the call could not be
completed" against a call that was still joining. A fabricated reason is worse
than no reason.

Attempts are now counted per client and compared before each step and before any
reporting, so a replaced flow abandons quietly and logs why, and only the
surviving flow delivers a token. `describe` names a cancellation instead of
letting it reach the generic branch.

Measurement used to establish this, against
`storage.signal.org/v2/groups/token` directly:

- no `Authorization` → 401
- one `Authorization`, 100–3000 bytes → 401
- one short plus one long → 401
- two long `Authorization` headers → **400**, nginx HTML, at every total size
  tried from 100 to 3000 bytes

## Call-related regression checks

Before changing call code, preserve:

- 1:1 audio remains usable when group-call work is disabled.
- Signal incoming call envelopes never become chat rows.
- Empty group-call/control updates never become chat rows.
- A group call is only ever reported `connected` when the native side said so.
  `NotConnected` and `Reconnecting` must not read as connected.
- A group call with no server-issued credential fails visibly. It never joins
  unverified.
- A group signal never claims a 1:1 `kind`, and an SFU request is always
  answered even when it could not be performed.
- Incoming calls are deduplicated and notification state is cancelled when the
  call is answered, declined, or ended.
- The group-token request carries exactly one `Authorization` header. Asserted
  by `call::tests::an_authorization_header_appends_rather_than_replaces`, which
  pins the reqwest append behavior the `Unidentified` override works around, so
  the fix cannot be silently reverted by a dependency bump.
- A repeated membership-proof request does not fail the call, does not release
  the native client, and does not deliver a second token. Covered by
  `aSecondProofRequestSupersedesTheFirstWithoutFailingTheCall` and
  `aSupersededFlowDoesNotDeliverItsToken`.
- A cancellation is never described as a join failure
  (`aCancellationIsNotDescribedAsAJoinFailure`).
- An SFU request that could not be performed is never decoded as an SFU refusal
  (`aRequestThatCouldNotBePerformedIsNotAnSFURefusal`), and a header value
  containing a NUL is refused rather than truncated into two headers
  (`anSFUHeaderContainingNULIsRefused`).
- C strings handed to the FFI are valid at the moment of the call, not only inside
  the closure that created them (`sfuHeaderStringsOutliveTheirScope`). This test
  is verified to fail against the dangling-pointer version.
- SFU requests run on the core the controller was configured with, never a
  default-constructed one
  (`theSFUPathUsesTheConfiguredBridgeRatherThanAFreshCore`).
- A `404` from the SFU participants poll is a call that ended, not a failed call
  (`aNotFoundPollMeansTheConferenceIsGoneNotThatTheCallFailed`).
- A join state is never mapped to a connection phase
  (`aJoinStateIsNotMappableToAConnectionPhase`). `Joined(1087663680)` carries the
  SFU's room id and is not a thing the user is shown; only a `Connected`
  connection state may show a call as connected.
