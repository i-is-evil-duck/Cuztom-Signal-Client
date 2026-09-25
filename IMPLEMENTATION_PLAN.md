# Cuztom Signal Implementation Plan

_Last updated: 2026-09-25_

## 1. Purpose and current assessment

Cuztom Signal is a native macOS linked-device Signal client. The project has a
substantial working implementation, but it should currently be treated as a
**beta/pre-production client**, not a production release.

The linked-device happy path is implemented and has been manually exercised:

- QR provisioning and linked-session resume
- Signal websocket receive loop and roster/group synchronization
- 1:1 and group text messaging
- Attachments, metadata-only history rows, downloads, and local rendering
- Reactions, replies, edits, delete-for-me/for-everyone, receipts, and typing UI
- Local macOS notifications
- Native 1:1 RingRTC voice calls

The main risk is not a lack of features; it is correctness and lifecycle
reliability around live state, persistence, account switching, native FFI
state, and security boundaries. Those issues should be addressed before
adding more product features.

This document converts the latest codebase review into an implementation plan
and roadmap.

---

## 2. Verification baseline

The following checks were run during the latest review:

| Check | Result |
|---|---|
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | 161/161 passed |
| `swift build --target CuztomSignalCore` | Passed |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product CuztomSignal` | Passed |
| `cargo test --all-targets` | 57/57 passed |
| `cargo check --all-targets` | Passed with warnings |
| `cargo build --release` | Passed with warnings |
| `cargo clippy --all-targets -- -D warnings` | Not run: Clippy component unavailable |
| `cargo fmt --all -- --check` | Not run: rustfmt component unavailable |
| Default Command Line Tools Swift build | Fails because the `SwiftUIMacros` plugin is unavailable |

The test suite covers controller lifecycle, account-switch task cancellation,
queued call actions through an injectable native bridge, encrypted SQLite
storage, and the native executor/epoch/gate primitives. It does not cover the
SwiftUI application views, real native FFI success paths, or a two-client
Signal/RingRTC integration.

---

## 3. Priority findings from the review

### P0 — correctness, lifecycle, and data integrity

These block reliable use with real accounts.

#### P0-1: Live controller state is not propagated to SwiftUI

`ChatController` updates its private message/conversation state when live
messages, reactions, and receipts arrive, but `ChatViewModel` only uses the
incoming-message callback to create notifications. The view model is not
synchronized after those mutations.

**Impact:** Live messages can remain invisible, sidebar previews and unread
badges can be stale, and reactions/receipts can fail to appear until an
unrelated action triggers `sync()`.

**Required fix:** Add a single state-change callback after controller state is
updated. Invoke it for messages, reactions, receipts, connection changes,
selection changes, and local mutations.

#### P0-2: `RustCoreService` is unsynchronized and the native core is process-global

The Swift service remains a class marked `@unchecked Sendable`, but its
mutable state is now explicitly serialized: account caches use a recursive
state lock, while library/init/pump state use dedicated lock-backed boxes.
Native command/poll FFI is serialized through a process-wide executor, and
every service FFI operation carries a session token checked before and after
native work. The remaining risk is task ownership and real-device integration,
not unserialized native or Swift state.

The Rust worker remains process-wide. The native core rejects conflicting
database paths while linked, and every remaining mutable Swift field now has an
explicit serialization boundary, so a literal actor conversion is no longer
required for Phase 1. A future actor/private-executor conversion is still an
option if the state grows.

**Impact:** Dictionary races, lost cache writes, duplicate initialization,
wrong-account operations, and corrupted UUID/path mappings.

**Required fix:** Serialize the Swift service through an actor/private
executor, enforce one native session per process, reject conflicting database
paths, and add an account/session generation to all asynchronous work.

#### P0-3: Logout and account switching are not atomic or fail closed

The app catches a native wipe failure and continues starting a new service.
The native `clearAllData()` path can delete an SQLite file while the worker
still owns an open store, ignores removal errors, and does not reset all native
initialization state.

The public `RustCoreService.logout()` path is only a partial logout. The
Keychain boundary is not wired into production, and pending composer state is
not cleared.

**Impact:** The old account can remain linked, old messages/attachments can
survive, and stale tasks can update a newly linked account.

**Required fix:** Implement one authoritative, throwing wipe operation. Stop
and await all tasks, quiesce the native receive loop, close stores, clear
account-bound caches and key material, verify deletion, and refuse to relink
after a failed wipe.

**Current status:** The native wipe runs behind the serial executor, the event
pump is cancelled and awaited, failed teardown poisons the service, and
cache/key removal is fail-closed. Controller/service/app tasks are now owned,
cancelled, and awaited before retry, logout, and account switch. The remaining
gap is real-device/two-client verification of the native success paths, not
Swift-side lifecycle ownership.

#### P0-4: SQLite paging and unread state are incorrect

`SQLiteMessageStore.messages(in:limit:)` uses `ORDER BY sentAt ASC LIMIT ?`,
returning the oldest page instead of the newest page. `loadMore()` can then
stop growing or display stale history.

Roster upserts overwrite unread counts with zero. Historical seed messages
are treated as new unread arrivals, while later refreshes can clear unread
badges.

**Impact:** New messages can disappear from the UI, history loading is broken,
and unread state is incorrect.

**Required fix:** Use newest-first cursor queries, distinguish historical
import from live arrival, preserve local unread state, and add tests with
201+ messages and repeated refreshes.

#### P0-5: Duplicate replays erase local message state

The in-memory and SQLite stores detect duplicate Signal identities but replace
the entire stored message with the incoming representation. Empty roster
values overwrite reactions, receipts, status, and attachment paths.

**Impact:** A refresh can erase live metadata and cause downloaded media to
disappear from the UI.

**Required fix:** Merge server content with local-only metadata and preserve
the most complete attachment/receipt/reaction state.

#### P0-6: Native edits, deletes, and typing events are dropped

The Rust event layer handles ordinary messages, reactions, receipts, and
calls, but does not emit edit, delete, or typing events. Swift has UI/model
support for typing but the Rust producer never emits the event.

**Impact:** Remote edits and deletes do not update the Swift store, and
incoming typing indicators are not reliable.

**Required fix:** Add normalized native event types and Swift handlers with
target timestamp, sender, thread, and author information.

#### P0-7: PNI and group control messages are routed incorrectly

Receipt and reaction paths strip `PNI:` and construct an ACI. Group reactions
and receipts bypass the GroupsV2 context used by ordinary group text.

Malformed group IDs are not validated before reaching presage, whose group
sender uses an `expect()` for a 32-byte master key.

**Impact:** PNI messages can be sent to the wrong identity, group control
messages can be rejected/misrouted, and malformed FFI input can panic a native
task.

**Required fix:** Preserve service-ID type, attach group context consistently,
validate all group keys as `[u8; 32]`, and return ordinary FFI errors instead
of panicking.

#### P0-8: Native history pages can be consumed by control envelopes

`rust-core/src/sync.rs::thread_page()` takes the newest raw store rows before
filtering receipts, reactions, edits, and other non-chat content. A page made
up entirely of control messages can return no chat rows while advancing the
cursor, causing older chat messages to become unreachable.

**Required fix:** Filter/control-classify before applying the page limit, or
continue fetching/overfetching until the requested number of chat messages is
returned. Add a fixture containing interleaved control and chat messages.

### P1 — security, privacy, and resource safety

#### P1-1: Native and presentation databases are unencrypted

The Rust store is opened without a passphrase. The Swift SQLite store and
UUID/path maps are plaintext. `KeychainSecretStore` exists but is not used in
production.

The native `clear_registration()` operation does not necessarily remove all
identity/master/account key material from the underlying store.

**Required fix:** Introduce encrypted SQLite storage, keep the passphrase in
Keychain with `ThisDeviceOnly` accessibility, protect cache files, and add a
verified full native key wipe.

**Status:** Both native and presentation stores now use SQLCipher with separate
Keychain-backed passphrases. Recognized legacy plaintext stores are migrated
through validated, atomic SQLCipher exports; unknown/encrypted files and wrong
keys fail closed. The presentation store uses the managed SQLCipher-enabled
GRDB fork and Swift 6.1 tooling, and authoritative logout closes/removes its
file and database-scoped key after clearing data. Encrypted attachment bodies,
full native key-material wipe verification, and identity challenge approval
remain pending.

#### P1-2: Unknown/changed identities are trusted automatically

The native store now rejects a changed key, but the pinned Presage SQLite
implementation still accepts first-seen identities by TOFU and does not expose
the candidate key or a challenge event. There is no safety-number or
identity-change confirmation UI.

**Required fix:** Add a protocol-store challenge/approval layer that captures
unknown and changed candidates, exposes safety numbers, and atomically approves
or rejects them without bypassing the encrypted store.

#### P1-3: The dylib loader trusts writable paths

The loader searches the executable directory, Application Support, and the
current working directory, then calls `dlopen()` without signature, hash, or
ABI validation.

**Required fix:** Load only a signed bundled dylib in release builds, remove
the current-directory fallback, verify code signature/hash, and negotiate an
ABI version before resolving function pointers.

**Status:** Implemented: checkout/cwd inference is removed, an explicit
`CUZTOM_SIGNAL_CORE_PATH` is available for debug builds, release builds require
bundle/signature validation with optional SHA-256 pinning, and `core_abi_version`
is checked before other symbols are used.

#### P1-4: Attachment processing can exhaust resources

Uploads read the whole file before checking the size limit. Missing size
metadata bypasses the auto-download limit. Live downloads block the receive
loop and fully buffer responses. Several Rust queues are unbounded.

**Required fix:** Check metadata before reading, stream with hard byte limits,
reject unknown sizes for automatic downloads, move downloads off the receive
loop, bound queues, and add cache quotas/eviction.

**Status:** Implemented metadata preflight, unknown/oversized download
rejection, a 500 MB attachment-cache quota, receive-loop decoupling, bounded
core/call/sync-control queues, and file protection. The presage attachment API
still returns a bounded in-memory body; true streaming transport remains
follow-up work.

#### P1-5: Link previews create an automatic network/privacy path

Rendering a message automatically fetches detected URLs and remote images
without user opt-in, private-network blocking, response-size limits, or
redirect validation.

**Required fix:** Make previews opt-in, allow only approved HTTPS/public
hosts, block loopback/private/link-local destinations after redirects, cap
responses, and use an isolated ephemeral URL session.

#### P1-6: Notifications and diagnostics retain sensitive plaintext

Notifications contain full message bodies, and native stdout/stderr is
redirected to an unbounded persistent log containing identifiers and paths.
Logout does not remove or redact the log.

**Required fix:** Add notification preview redaction, redact identifiers,
rotate/limit logs, and define a logout retention policy.

#### P1-7: Receipts lack thread scope and stable sender identity

Rust receipt events contain sender/timestamp information but no conversation
thread. `ChatController.applyReceipt()` scans every conversation and matches
only timestamps, while the Swift layer prefers a display name over the stable
sender ID.

**Impact:** A receipt can update the wrong conversation if timestamps collide,
and receipt rows can later display as `Unknown` when the display-name string
is treated as an ACI/PNI identifier.

**Required fix:** Include thread and stable sender service ID in receipt
events/models, and use a separate display-name lookup for presentation.

**Status:** Implemented by resolving receipt target timestamps against the
native store before delivery, retaining the stable sender service ID, and
dropping ambiguous receipts instead of applying them to every conversation.

#### P1-8: Manual attachment paths are not persisted across relaunches

`RustCoreService.bindLocalPath()` only updates the in-memory `localPaths` map.
The persisted path cache is not updated when the user manually downloads an
attachment.

**Impact:** After relaunch, the cached file exists but the message loses its
`localURL` and shows Download again.

**Required fix:** Persist manual paths through the same account-scoped path
cache used for live/sent attachments, with validation and eviction.

**Status:** Implemented with file-existence and app-cache-root validation,
account/database-scoped map namespaces, logout/wipe cleanup, persisted lookup
aliases, and protected cache files. Media eviction/quotas remain part of the
broader cache work.

#### P1 tranche completed 2026-09-25

- [x] Default link previews to off; fetch only approved public HTTPS pages,
  reject unsafe redirects, avoid remote image fetches, and cap response size.
- [x] Redact notification content by default and clear bounded diagnostics on
  successful logout.
- [x] Persist manual attachment paths and hydrate them after service restart;
      isolate maps by database/account namespace and remove them on logout.
- [x] Bound the sync-control queue and fail explicitly on saturation; shutdown
      waits for a reserved control slot with a timeout.
- [x] Resolve receipt scope from native target timestamps, retain stable sender
      IDs, and drop ambiguous cross-conversation acknowledgements.
- [x] Remove implicit native-library search paths and gate release loads on
      bundle/signature/hash/ABI validation.
- [x] Bound command/call/sync-control intake, reject unknown/oversized media,
      move receive-loop downloads to the Swift fetcher, and enforce an
      attachment-cache quota.
- [x] Apply complete file protection to presentation/native data and use
      device-only Keychain accessibility for secrets.
- [x] Add ABI-v2 `core_cmd_init_encrypted`, strict Keychain key loading, and
      validated SQLCipher migration for recognized legacy native stores.
- [x] Move the Swift presentation store to the SQLCipher-enabled GRDB fork;
      add separate Keychain key management, atomic plaintext migration, and
      wrong-key regression coverage.
- [x] Add a terminal presentation-store destroy path that closes the queue
      before removing the encrypted file and database-scoped Keychain key.
- [ ] Block first-seen identities and add a safety-number challenge/approval
      workflow; the pinned Presage store still requires a protocol-layer patch.

### P2 — reliability, UX, and maintainability

- Receipt settings do not control actual network behavior.
- Read receipts are repeatedly sent because there is no local read cursor.
- Reactions store only `[String]` and cannot represent multiple senders.
- [x] Scope composer state to a conversation; keep regression coverage for
  delayed sends and account switches.
- [x] Fix clipboard image staging so it does not delete its own source.
- [x] Isolate same-basename attachments in conversation-scoped staging paths.
- Failed attachment sends still delete staged files.
- Edit failures close the editor and discard the draft.
- SQLite errors are converted into empty/false results indistinguishable from
  duplicate/not-found results.
- Sync errors do not trigger reconnect/backoff.
- Link timeout can leave the native worker stuck in `Linking`.
- The first send can occur before the receive queue/session is ready.
- Call mute can update the UI even if the native call fails.
- Speaker and video toggles are currently cosmetic.
- Call answer state can be overwritten by the view model.
- [x] Guard rapid outgoing-call taps while microphone permission/native start
      is pending, and invalidate stale call callbacks across reset/configure.
- [x] Cancel delivered incoming-call notifications when the remote call ends
      or the incoming overlay is dismissed.
- Queued RingRTC signals have no account generation and can cross a
  logout/relink boundary.
- [x] Remove the Character Viewer observer when its coordinator deallocates;
      the private selector remains an explicit compatibility limitation.
- QR expiration is not displayed or enforced.
- Negative paging limits can trap.
- SQLite schema migration is not versioned.
- Attachment images are loaded synchronously on the UI path.
- [x] Make expanded video playback and thumbnail tasks URL-keyed and
  cancellation-safe, with one visible transport bar.

---

## 4. Roadmap

The roadmap is ordered by dependency and risk. Do not begin broad feature
expansion until Milestone 2 is complete.

### Milestone 0 — Establish a safe development baseline

**Goal:** Make builds, tests, and native integration reproducible before
changing behavior.

- [x] Commit `Package.resolved`.
- [x] Commit `rust-core/Cargo.lock`.
- [x] Pin `presage` and `ringrtc` Git revisions/tags.
- [x] Add `rust-toolchain.toml` and document the supported Swift 6.1 /
      Xcode 16.3+ / macOS 14+ / Rust versions.
- [x] Add a macOS CI workflow for full-Xcode Swift tests/builds and native
      Rust tests/checks/builds.
- [ ] Add strict `cargo fmt` and Clippy gates once the current warning/toolchain
      baseline is cleaned up.
- [x] Add an ABI/version symbol exposed by the Rust library.
- [x] Add a versioned C header and a parity check for every exported ABI symbol.
- [x] Fix the current AppKit actor-isolation warning in the emoji picker.
- [ ] Audit and explicitly handle remaining ignored Swift operation results.
- [x] Make the native integration test fail when CI supplies a native path;
      local runs without a built dylib may still skip explicitly.

**Exit criteria:** A clean checkout builds the same dependency graph and
fails CI if the native library is missing or ABI-incompatible.

---

### Milestone 1 — Fix live state and storage correctness

**Goal:** Make the existing text-message experience correct under normal use.

- [x] Add `ChatController.onStateChange` and connect it to the view model.
- [x] Ensure live messages, reactions, receipts, and connection changes update
      the UI immediately.
- [x] Fix `SQLiteMessageStore.messages(in:limit:)` to return the newest page
      in chronological display order.
- [x] Replace `loadMore()` boolean semantics with success/exhausted/failure
      results.
- [x] Protect `loadMore()` and refresh results with a selection/session
      generation.
- [x] Fix initial paging when the Swift cache is empty.
- [x] Push store-timestamp ordering and limits into the native SQLite query.
- [x] Filter non-chat control envelopes before applying native page limits.
- [x] Preserve unread counts during roster metadata upserts.
- [x] Add a separate historical import mode that does not mark old history
      unread.
- [x] Merge duplicate message records instead of replacing them.
- [x] Recompute conversation preview/activity/unread state after deletion.
- [x] Add a failure-aware authoritative storage wipe path.
- [x] Add production SQLite tests with 201+ messages, refreshes, replay, and
      unread state.
- [ ] Add storage failure-injection tests.

**Exit criteria:** Live messages appear without manual refresh, 500-message
paging has no gaps/duplicates, unread state survives refresh, and local
metadata survives replay.

#### P0 rendering follow-up (completed 2026-09-24)

- [x] Persist and hydrate reply references, including quote-only messages.
- [x] Render reaction chips and hydrate reaction summaries from native roster
      snapshots; route self-authored control envelopes by destination.
- [x] Render reply previews and navigate/scroll to loaded quoted messages.
- [x] Bound link, image, GIF, and video media to a chat bubble width.
- [x] Rebuild the expanded video surface with one visible transport bar and
      URL-keyed/cancellation-safe loading.
- [x] Isolate drafts, replies, staged files, errors, and upload state per chat.

---

### Milestone 2 — Make session lifecycle and native state safe

**Goal:** Prevent cross-account leakage and make logout/retry reliable.

- [x] Finish serializing `RustCoreService` mutable state: cache maps use the
      state lock, while library/init/pump state use dedicated lock-backed
      boxes; a literal actor conversion is no longer required for Phase 1.
- [x] Move native command, initialization, polling, and call FFI calls to a
      process-wide serial background executor; keep the synchronous loader as
      a compatibility seam.
- [x] Enforce one native worker/account per process.
- [x] Reject initialization with a different database path while linked.
- [x] Add a lock-backed service session epoch and invalidate the native event
      pump before logout/wipe/relink.
- [x] Serialize lifecycle transitions with an async gate; a concurrent
      begin/relink cannot overtake teardown.
- [x] Share the session epoch and lifecycle gate by canonical database path
      across service instances; suspend and poison failed teardown until
      explicit relink.
- [x] Route command/event/call FFI operations through token-bound session
      checks and a process-wide serial background executor.
- [x] Drain or invalidate queued RingRTC signals/actions during logout before
      allowing relink.
- [x] Guard call startup so rapid taps cannot create duplicate native calls;
      the in-flight flag and lifecycle generation fence the post-FFI commit.
- [x] Track and await all controller/service tasks: `ChatController` callback
      hops, watcher/refresh/auto-fetch, and `CallController` accept/end/mute
      work are registered, cancelled, and awaited during teardown.
- [x] Track app selection/diagnostics tasks and await them before retry/logout.
- [x] Cancel watcher, refresh, selection, auto-fetch, and diagnostic tasks
      before logout/retry, including an awaited `ChatController.shutdown()`
      when a retry or account switch retires the old controller.
- [x] Make `clearAllData()` throw on any failure and never continue relinking
      after failure.
- [x] Add a native shutdown/reset operation that closes stores and returns
      the worker to a genuinely fresh state.
- [x] Reset `didInit`, `selfAci`, path maps, UUID maps, resolver state, and
      pending composer/call state.
- [x] Clear pending files and drafts on account switch.
- [x] Add regression coverage for epoch retirement, queued/in-flight native
      cancellation semantics, lifecycle-gate ordering, idempotent unlinked
      logout, explicit relink gating, failed native/presentation teardown
      poisoning, and cross-instance refusal.
- [x] Add a delayed-service integration regression proving a stale
      `finish()` continuation cannot publish after logout.
- [x] Add regressions proving an old watcher stops before an account switch and
      that a late native sync/edit/delete/receipt/typing callback cannot publish
      into a retired controller.
- [x] Add full controller/native integration coverage for logout failure,
      account switching, task cancellation, and queued call actions, using an
      injectable `CallNativeControlling` bridge so call actions are testable
      without booting RingRTC.

**Exit criteria:** Logging out cannot resume the old account, and no callback
or task from account A can update account B.

#### Milestone 2 — code complete 2026-09-25

All Milestone 2 code items are implemented and covered by the Swift suite. The
only remaining Phase 1 work is manual verification that cannot be produced in
this environment:

- Link a real phone and a real Mac client, then confirm logout, relink, and
  account switching on device.
- Exercise reconnect/offline soak and queued native call actions against the
  real RingRTC stack.
- Confirm Keychain and SQLCipher behavior inside a signed application.

These are tracked in the two-client integration section below and must stay
open until they are actually run.

#### Phase 1 manual verification status 2026-09-25

A first real-device pass confirmed linking, messaging, media, and a two-way
1:1 call, and surfaced one packaging finding:

- An ad-hoc signature is derived from the binary, so every rebuild is a new app
  identity to macOS. The app now re-prompts for access to the existing Signal
  database key on each rebuild, and the encrypted message store cannot be
  opened until the user approves it. This is expected for ad-hoc signing, not a
  storage regression, but it must be re-checked with a stable Developer ID
  (Milestone 7) before any release claim.

Real logout, relink, and account switching on device are still to be run.

---

### Milestone 3 — Complete native message protocol semantics

**Goal:** Make the advertised messaging features work for incoming traffic.

- [x] Add native `edit`, `delete`, and `typing` event extraction.
- [x] Add Swift event models and store reconciliation handlers.
- [x] Extract quote metadata from direct and synchronized messages, including
      quote-only rows.
- [x] Aggregate native roster reaction summaries and preserve them through
      Swift store hydration.
- [x] Preserve PNI service IDs in quote paths.
- [ ] Preserve PNI service IDs in contact, reaction, receipt, and edit paths.
- [x] Include thread and stable sender identity in receipt events/models.
- [x] Persist manually downloaded attachment paths through the account-scoped
      path cache.
- [x] Attach GroupsV2 context/revision to all group control messages.
- [x] Validate group IDs before native calls.
- [ ] Add exact attachment lookup by stable message identity rather than a
      loose timestamp range.
- [ ] Distinguish empty event queues from worker errors.
- [ ] Wait for initial sync/session readiness before allowing first send.
- [x] Add reply, reaction-snapshot, quote-only, paging, and replay regression
      tests.
- [ ] Add the remaining PNI, group, edit, delete, typing, and malformed-input
      integration tests.

**Exit criteria:** Remote edits/deletes/typing update immediately, PNI and
group control messages route correctly, and malformed input returns an error
without crashing the worker.

---

### Milestone 4 — Security and privacy hardening

**Goal:** Make local data and native loading safe for real users.

- [x] Add encrypted SQLite support and Keychain-backed passphrase storage.
- [x] Migrate existing plaintext databases with a tested migration path.
- [ ] Add identity-change verification/safety-number UI.
- [x] Bundle and sign the native dylib; remove user-writable search paths.
- [x] Verify native code signature/hash and ABI version before `dlopen()`.
- [x] Add notification preview redaction with an explicit opt-in setting.
- [x] Redact identifiers/paths, cap diagnostic logs, and clear them after a
      successful account wipe.
- [x] Make link previews opt-in and restrict them to safe public HTTPS hosts.
- [x] Add private-network/redirect/response-size protections for link previews.
- [ ] Define secure deletion and retention behavior for databases, media,
      logs, and notification content.

**Exit criteria:** A filesystem/backup reader cannot recover message or key
material without the Keychain-protected passphrase, and a replaced native
library cannot be loaded silently.

---

### Milestone 5 — Calls and media reliability

**Goal:** Make the supported 1:1 voice path predictable and honest about
unsupported features.

- [ ] Make mute state update only after native success.
- [ ] Implement or remove speaker routing controls.
- [ ] Implement or remove video controls and camera permission handling.
- [ ] Implement a real decline signal instead of labeling a normal hangup as
      declined locally.
- [ ] Fix call state replay when native callbacks arrive before Swift ID
      mapping.
- [ ] Fix view-model answer-state races.
- [ ] Cancel incoming-call notifications on every terminal state.
- [ ] Add call session tests for permission denial, glare, remote hangup,
      timeout, lost callbacks, and logout during a call.
- [ ] Keep group-call and full-video features disabled until their native
      requirements are complete.

**Exit criteria:** UI state always reflects the actual native call state, and
no unsupported control is presented as functional.

---

### Milestone 6 — Product completion

**Goal:** Add remaining user-facing features only after the core is reliable.

- [ ] Group administration: create, rename, avatar, members, roles, leave.
- [ ] Authenticated TURN relay discovery.
- [ ] APNs/VoIP push and killed-app delivery.
- [ ] Launch-at-login, background lifecycle, and reconnect policy.
- [ ] CallKit/system call UI and lock-screen actions.
- [ ] Group calls after membership-proof/SFU work is complete.
- [ ] Disappearing-message timers.
- [ ] Cross-thread message search.
- [ ] Backup/restore.
- [ ] Crash reporting with redaction.
- [ ] Persistent call history if required by the product.

**Exit criteria:** Each feature has protocol fixtures, lifecycle tests, UI
tests, and documented privacy behavior before being enabled.

---

### Milestone 7 — Release engineering

**Goal:** Produce a reproducible, signed, notarized macOS build.

- [ ] Create a real `.app`/XCFramework packaging target.
- [ ] Include the Rust dylib in the signed bundle.
- [ ] Add microphone/camera entitlements and required `Info.plist` keys.
- [ ] Build arm64 and Intel artifacts reproducibly.
- [ ] Generate and version the native header.
- [ ] Add `codesign`, hardened-runtime, and notarization steps.
- [ ] Add a clean-machine smoke test that links and receives a message.
- [ ] Add dependency/license notices and AGPL compliance review.
- [ ] Add release artifact checksums and rollback instructions.

**Exit criteria:** A clean machine can install and run the signed app without
manual dylib copying, and the release is reproducible from a clean checkout.

---

## 5. Required test strategy

### Swift core tests

Add tests for:

- Live state propagation
- Selection races and stale async results
- 201+ SQLite messages and cursor boundaries
- Control-envelope-heavy native history pages
- Refresh/unread preservation
- Replay preserving reactions, receipts, status, and attachment paths
- Incoming edit/delete/typing events
- Receipt settings, thread scope, stable sender identity, and read-cursor
  behavior
- PNI and group routing
- Storage failures and deletion failures
- Logout/account-switch task cancellation
- Draft/reply/edit/attachment isolation by conversation

### Rust tests

Add tests for:

- FFI success/error paths and ABI symbols
- Malformed UTF-8, pointers, lengths, limits, and group IDs
- PNI service-ID preservation
- Group reaction/receipt context
- Edit/delete/typing event normalization
- Control-envelope-heavy history pages
- Receipt thread scope and stable sender identity
- Link timeout/retry and worker reset
- Full native key/database wipe
- Attachment size limits, missing sizes, cache collisions, and quotas
- Sync errors and reconnect behavior

### UI and integration tests

Add tests for:

- Start/retry/QR expiration/window restoration
- Live message/reaction/receipt/typing propagation
- Cross-conversation composer behavior
- Logout failure, relink, and account switching
- Notification authorization, routing, and call actions
- Call answer/decline/end races
- Duplicate call taps and queued call-signal logout races
- Clipboard/file staging and failed sends
- Link-preview URL filtering and response limits
- Video cancellation and thumbnail invalidation
- Dylib signature/ABI failures

### Two-client integration

Maintain a manual or automated two-client test matrix covering:

- Fresh link and resume
- 1:1 and group text
- Attachments and large-file limits
- Reactions, edits, deletes, receipts, and typing
- 1:1 voice calls and remote hangup
- Logout/relink/account switching

---

## 6. Current known limitations

The following remain intentionally incomplete or blocked:

- Group calls and SFU/membership-proof support
- Authenticated TURN relay discovery
- APNs/VoIP push and killed-app delivery
- Background reconnect and launch-at-login
- Group administration UI
- Full video calling and multi-call handling
- CallKit/system call actions
- Disappearing-message timers
- Cross-thread search
- Encrypted SQLite/keychain-backed storage
- Backup/restore and crash reporting
- Reproducible signed/notarized DMG distribution
- Sparkle or another signed update channel

Until these limitations are addressed, the app should be distributed only to
trusted testers and should not be presented as a complete Signal client.
