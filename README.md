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

- `Sources/CuztomSignalCore/RustCoreService.swift` — FFI seam, roster/message
  mapping, UUID/path caches, attachments, sync callbacks, and data wipe.
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
- `Sources/CuztomSignalCore/CallController.swift` — Swift call state machine.

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
```

The checked-in source does not include the local app bundle or user data.
The SQLCipher XCFramework is resolved as a pinned SwiftPM binary dependency and
must be embedded/signed with the app. For a local runnable bundle, copy the
built Swift executable and release dylib into `CuztomSignal.app/Contents/MacOS/`,
then ad-hoc sign the bundle.

## Verification status

| Area | Status |
|---|---|
| Swift core tests | **56 passed** with full Xcode |
| Rust library tests | **11 passed** |
| Rust release build | Passed; produces the native dylib |
| Swift app build | Passed with full Xcode |
| QR link/resume | Manually verified |
| Contacts/groups/name resolution | Manually verified after fresh reset |
| 1:1/group text routing | Manually verified |
| Duplicate/control-envelope cleanup | Verified against the local encrypted SQLite store |
| Presentation SQLCipher migration | Plaintext export, encrypted reopen, and wrong-key rejection tested |
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
IMPLEMENTATION_PLAN.md           Detailed completion/open-work status
CALLS_PLAN.md                    Native call implementation and limitations
TODO.md                          Prioritized remaining work
```

## License and distribution

Review the AGPLv3 obligations of `libsignal`/`presage` before distributing a
binary. The current local bundle is ad-hoc signed and is not a notarized
consumer release.
