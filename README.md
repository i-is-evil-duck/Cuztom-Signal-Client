# Cuztom Signal — native macOS Signal client

Cuztom Signal is a lightweight, linked-device Signal client for macOS. The
phone remains the primary device; this app uses Signal's native linked-device
protocol through `presage`/`libsignal` rather than `signal-cli`, Docker, or a
virtual audio device.

> **Legal/support note:** `libsignal` and `presage` are AGPLv3. Third-party
> Signal clients are unsupported by Signal and may be rate-limited. This is not
> an App Store product; distribution should use a signed/notarized build with
> appropriate licensing disclosures.

## Current status — 2026-09-25

### Working

- Native QR linking and resuming an existing linked session.
- Native Signal websocket receive loop, contact/groups sync, roster refresh,
  and reconnect-safe local persistence.
- 1:1 and group text messaging with GroupsV2 context attached to outgoing
  group messages.
- Group conversation routing is canonicalized through
  `contact:<service-id>` / `group:<master-key>` thread IDs.
- SQLCipher-encrypted SQLite message/conversation storage with logical message
  deduplication, startup migration cleanup, unread-count protection, and
  persistent UUID/path mappings.
- Friendly contact/group names, group-member profile-key fallback resolution,
  initials, Note to Self/You labeling, and sender-name hints from decrypted
  envelopes.
- Sender chips appear only on the first message in a contiguous incoming run
  from the same group sender.
- Reactions, replies, edits, delete-for-me/for-everyone, incoming typing
  indicators, read/delivery receipt display, and link previews.
- Attachment upload/download, metadata-only rows, on-demand downloads, image
  and video rendering, animated GIF support (including extensionless legacy
  cache files), and per-attachment cache paths.
- Empty reaction/group-call/control envelopes are no longer rendered as blank
  chat messages.
- Local macOS notifications for newly received messages and incoming calls,
  with notification settings and duplicate suppression.
- Idempotent logout/data wipe covering Rust state, Swift SQLite state, UUID and
  path maps, downloaded media, and keychain-backed session material.
- Process-wide serial native FFI/lifecycle coordination with token-bound
  session fences, cancellation-safe queued work, and cross-instance wipe poison.
- Native RingRTC-backed 1:1 voice calls with ICE/DTLS, microphone capture,
  mute, hangup, incoming/outgoing state, and elapsed time UI.

### Not yet complete

- Group calls. The 1:1 RingRTC path is intentionally isolated while Signal
  membership-proof retrieval, group/member identity derivation, SFU HTTP
  requests/responses, and opaque group-call signaling are implemented.
- Authenticated TURN relay discovery and reliable calls to a fully offline
  peer. The current sender does not expose Signal's urgent-message flag.
- APNs/VoIP push, launch-at-login/background keepalive, and killed-app
  notification delivery. Current notifications are local notifications while
  the app process is running.
- Group administration UI: create/rename groups, avatars, member add/remove,
  roles, and leave-group flows.
- Full video calling, group video, multi-call handling, CallKit integration,
  and lock-screen call controls.
- Disappearing-message timers, cross-thread message search, backup/restore,
  notarized DMG/Sparkle distribution, and crash reporting.
- Signal does not sync pre-link history to a newly linked device; history
  accumulates from link time forward.

## Architecture

```text
SwiftUI Views (XcodeApp/Sources)
  -> ChatViewModel (@Observable, main actor)
    -> ChatController (Sources/CuztomSignalCore)
      -> SignalService protocol
        -> RustCoreService (dlopen/dlsym)
          -> presage Manager + libsignal + Signal websocket
          -> RingRTC native 1:1 call engine
      -> MessageStore actor (SQLCipher/GRDB in production)
      -> SecretStore (separate native/presentation Keychain keys)
```

Important implementation areas:

- `Sources/CuztomSignalCore/RustCoreService.swift` — token-bound FFI seam,
  roster/message mapping, UUID/path caches, attachments, sync callbacks, and
  data wipe.
- `Sources/CuztomSignalCore/SerialNativeExecutor.swift` — process-wide serial
  queue for blocking native Signal/RingRTC calls and teardown ordering.
- `Sources/CuztomSignalCore/BuildInfo.swift` — bundle/CI build tag used by the
  UI and diagnostics.
- `Sources/CuztomSignalCore/AsyncOperationGate.swift` and
  `NativeProcessState.swift` — process-wide lifecycle serialization,
  shared database-path session epochs, and cross-instance wipe-poison
  protection.
- `Sources/CuztomSignalCore/RustCoreServiceStateBoxes.swift` — lock-backed
  storage for the dylib handle, native init/linked state, and the event-pump
  task.
- `rust-core/src/sync.rs` — message normalization, stable timestamps, control
  envelope filtering, attachment metadata, profile/group-member resolution,
  and send helpers.
- `Sources/CuztomSignalCore/PresentationDatabaseSecurity.swift` — SQLCipher
  configuration, Keychain key handling, and atomic plaintext migration.
- `Sources/CuztomSignalCore/SQLiteMessageStore.swift` — durable encrypted
  message store and startup migration/deduplication.
- `XcodeApp/Sources/Views.swift` — message list, sender-run chips, media
  rendering, and scrolling.
- `XcodeApp/Sources/NotificationManager.swift` — local macOS notifications.
- `Sources/CuztomSignalCore/CallController.swift` — Swift call state machine,
  tracked accept/end/mute tasks, and the `CallNativeControlling` seam that lets
  call actions be tested without booting RingRTC.
- `Sources/CuztomSignalCore/AudioOutputRouter.swift` — CoreAudio output routing
  for the call speaker toggle.
- `Sources/CuztomSignalCore/GroupCallProofService.swift` — group-call
  membership-proof redemption at the CDN. Partial: it takes the authorization
  value from the native core, but nothing supplies that yet, so no group call
  can complete. See `CALLS_PLAN.md`.

## Build and test

Full Xcode is required for the SwiftUI executable and Swift Testing macros.
The package uses the SQLCipher-enabled GRDB fork and requires Swift 6.1 /
Xcode 16.3 or newer on macOS 14+. The core target can be built with the
command-line tools.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Core tests
swift test

# App executable
swift build --product CuztomSignal

# Rust core (the repository includes a macOS realpath shim for RingRTC)
cd rust-core
PATH="$PWD/scripts:$PATH" cargo test
PATH="$PWD/scripts:$PATH" cargo build --release

# Runnable, ad-hoc signed bundle in build/CuztomSignal.app
scripts/build-app.sh            # optional: scripts/build-app.sh 0.2.0 3
```

The checked-in source does not include the local app bundle or user data.
`scripts/build-app.sh` assembles `build/CuztomSignal.app`: it embeds the
release dylib next to the executable, embeds the pinned SQLCipher XCFramework
(and adds the `@executable_path/../Frameworks` rpath it needs), ad-hoc signs
everything, and records the signed dylib's SHA-256 in `Info.plist`. The sign →
hash → `Info.plist` → sign order matters: re-signing the dylib afterwards
invalidates the recorded hash. `scripts/verify-app.sh` re-checks a bundle
against the same rules the release loader enforces (in-bundle path, strict
nested signature, hash, native ABI version), so a broken bundle fails there
instead of showing "rust core not found" in the UI.

The UI build tag comes from `CFBundleShortVersionString`/`CFBundleVersion`; a
bundle built by the script shows e.g. `Build 0.1.0 (1)`, local SwiftPM runs show
`Build dev`, and CI can override it with `CUZTOM_SIGNAL_BUILD_TAG`.

An ad-hoc signature is derived from the binary, so every rebuild produces a new
app identity. macOS therefore re-prompts for access to the existing Signal
database key after each rebuild; choose **Always Allow** in that dialog, or the
app cannot decrypt its message store. A stable Developer ID removes this
friction (see Milestone 7).

## Verification status

| Area | Status |
|---|---|
| Swift core tests | **152 passed** with full Xcode |
| Rust library tests | **52 passed** |
| Rust release build | Passed; produces the native dylib |
| Swift app build | Passed with full Xcode |
| Ad-hoc signed bundle | Built and launched; embedded dylib passes in-bundle/signature/hash/ABI checks |
| Call audio routing | Built-in ⇄ headset toggle via the CoreAudio default output; verified by unit tests on real devices |
| QR link/resume | Manually verified |
| Contacts/groups/name resolution | Manually verified after fresh reset |
| 1:1/group text routing | Manually verified |
| Duplicate/control-envelope cleanup | Verified against the local encrypted SQLite store |
| Presentation SQLCipher migration | Plaintext export, encrypted reopen, and wrong-key rejection tested |
| Keychain access in a signed app | Ad-hoc rebuilds re-prompt for the database key; stable-identity behaviour still open (Milestone 7) |
| 1:1 native voice call | Manually verified with two-way audio |
| Group call | Not enabled; blocked on SFU/membership-proof work |
| 500-message paging | Still needs a dedicated manual test |
| Large attachment round-trip/limits | Still needs a dedicated manual test |

## Repository layout

```text
Package.swift
Sources/CuztomSignalCore/       Core models, services, stores, controllers
XcodeApp/Sources/               SwiftUI app and macOS notification coordinator
Tests/CuztomSignalCoreTests/    Swift Testing coverage
rust-core/                      Rust presage/libsignal/RingRTC core and C ABI
scripts/                        Local app bundle build and preflight checks
IMPLEMENTATION_PLAN.md           Detailed completion/open-work status
CALLS_PLAN.md                    Native call implementation and limitations
TODO.md                          Prioritized remaining work
```

## License and distribution

Review the AGPLv3 obligations of `libsignal`/`presage` before distributing a
binary. The current local bundle is ad-hoc signed and is not a notarized
consumer release.
