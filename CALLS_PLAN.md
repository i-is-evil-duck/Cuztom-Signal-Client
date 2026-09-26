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

- ICE currently uses public STUN servers. Signal's authenticated TURN relay
  list is not fetched yet, which is a real limit on 1:1 connectivity between
  restrictive networks.
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

The distinction that cost the most time: a bare nginx `400` HTML page is not the
application saying the parameters are wrong. It says the request never got
there. `group_auth_credentials_raw` worked at the same moment `group_call_token`
did not, from the same client, on the same day — the difference was that only the
latter added a second `Authorization` header.

The same reasoning applies to a `2xx` that will not decode. A `200` is not
evidence that the body is the message expected, and it is not evidence that a
token was issued. Both are claimed only once the body is parsed, and the format
is logged so a mismatch names itself.

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
