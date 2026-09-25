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
| 5 | Group-call lifecycle + opaque signaling transport | Rust | Fake SFU client | **In progress** — proof trigger + member framing done | 🟡 |
| 6 | `GroupCallController` + UI | Swift | Against the fake bridge | Not started | ⬜ |

Increments 3 and 4 come early on purpose: a wrong basic-auth header or a
stalled SFU request is invisible until a real call connects, so both are the
pieces most worth proving with tests before anything is built on top of them.

### ABI 3

`core_cmd_http_response` is new in ABI 3. Older dylibs lack the symbol, so the
Swift loader rejects them at `core_abi_version` instead of loading a core that
would leave every SFU request unanswered. A pre-ABI-3 bundle therefore fails
loudly at startup rather than hanging on join.

### Still to do in increment 5

The membership-proof trigger and the member-identity framing are in place, so
the proof path is now complete from RingRTC's request through to the token being
handed back. Remaining:

- Commands to create a group call client, `connect`, `join`, `leave`, and
  `delete`, backed by `CallManager::create_group_call_client`.
- Outbound signaling: `SignalingSender::send_call_message_to_group` still
  returns "group calls are not supported". It needs the RingRTC bytes wrapped
  in a Signal `CallMessage.opaque` and sent via presage's
  `send_message_to_group`, which requires resolving RingRTC's 32-byte group id
  back to the group master key.
- Inbound signaling: `sync::call_signal_part` drops a `CallMessage` that
  carries only `opaque`, so group-call messages never reach
  `CallManager::received_call_message`.

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

## Known 1:1 limitations and follow-ups

- ICE currently uses public STUN servers. Signal's authenticated TURN relay
  list is not fetched yet.
- The current sender does not expose Signal's urgent-message flag, so a call to
  a fully offline phone may not produce a push notification.
- Ringtone/ringback audio and full system audio-route selection are not
  implemented.
- Video calling is not enabled in the production UI; the current supported
  call mode is voice.
- Group/video calls, CallKit, lock-screen call actions, multi-call handling,
  and persistent call history remain future work.
- APNs/PushKit, launch-at-login, and killed-app call delivery require a
  separate signed provider/APNs path and are not implemented.

## Call-related regression checks

Before changing call code, preserve:

- 1:1 audio remains usable when group-call work is disabled.
- Signal incoming call envelopes never become chat rows.
- Empty group-call/control updates never become chat rows.
- Incoming calls are deduplicated and notification state is cancelled when the
  call is answered, declined, or ended.
