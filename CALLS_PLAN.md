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
