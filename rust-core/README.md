# rust-core — native Signal service core

`rust-core` is the Rust side of Cuztom Signal. It combines:

- `presage` linked-device provisioning and Signal websocket receive/send.
- `libsignal` cryptography, identities, profiles, GroupsV2, and SQLite storage.
- Native RingRTC/WebRTC support for the current 1:1 voice-call path.
- A C ABI consumed by `RustCoreService` through `dlopen`/`dlsym`.

The crate is built as an `rlib`, `staticlib`, and `cdylib`. Swift does not
link the Rust crate directly; it loads the release dylib at runtime.

## Current capabilities

- QR link provisioning, linked-session resume, roster/whoami, contact sync,
  websocket events, and local SQLite message storage.
- 1:1 and group text, attachments, replies (including quote-only rows), edits,
  reactions, delete tombstones, receipts, and incoming typing events.
- Native roster/page snapshots retain reply references and aggregate reaction
  summaries for hydrated messages.
- Stable client/store-timestamp message keys, UUID migration support, and
  logical deduplication in the Swift store.
- Attachment MIME/name normalization, extensionless GIF-compatible cache
  paths, stable per-attachment paths, and bounded auto-download.
- Filtering of empty reaction/group-call/control envelopes before they become
  chat messages.
- Profile-name lookup with group-member profile-key fallback.
- Native RingRTC 1:1 offer/answer/ICE/hangup/busy signaling and call state.
- Explicit data/logout cleanup support for the Swift app.
- Native ABI gating, release bundle/signature/hash checks, bounded command/call
  intake, oversized/unknown attachment rejection, a 500 MB media-cache quota,
  and file-protection metadata for native data/caches.

Group calls, authenticated TURN, APNs/urgent delivery, and the group-call SFU
HTTP/membership-proof path are not complete.

## Prerequisites

Verified on macOS arm64:

- Rust stable toolchain (the current verification used Rust 1.98.1).
- Full Xcode for the Swift app/tests.
- `protoc` for the libsignal/SPQR build scripts (`brew install protobuf`).
- Network access for the Git/prebuilt-WebRTC dependencies on the first build.

RingRTC's build script probes GNU `realpath -e`. This repository includes a
macOS shim at `rust-core/scripts/grealpath`; put that directory on `PATH`
when building.

## Commands

From the repository root:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
swift build --product CuztomSignal
```

Rust commands:

```bash
cd rust-core
PATH="$PWD/scripts:$PATH" cargo check
PATH="$PWD/scripts:$PATH" cargo test --lib
PATH="$PWD/scripts:$PATH" cargo build --release
```

The release library is written to:

```text
rust-core/target/release/libcuztom_signal_core.dylib
```

For a local debug run outside an app bundle, point the loader at that build
explicitly; the loader no longer infers a path from the current directory:

```bash
export CUZTOM_SIGNAL_CORE_PATH="$PWD/rust-core/target/release/libcuztom_signal_core.dylib"
```

Release app bundles must place the dylib inside the signed bundle. The Swift
loader checks its code signature, ABI symbol, and optional
`CUZTOM_SIGNAL_CORE_SHA256`/`CuztomSignalCoreSHA256` pin before loading.

For a local app bundle, copy that dylib next to the Swift executable in
`CuztomSignal.app/Contents/MacOS/` and ad-hoc sign the bundle. The app bundle
and user databases are intentionally not committed.

## Main C ABI surface

The exact declarations are in `src/lib.rs`; the important groups are:

- ABI gate: `core_abi_version` is checked before any other symbol is resolved.
- Session/sync: `core_cmd_init`, `core_cmd_begin_link`,
  `core_cmd_poll_link`, `core_cmd_is_linked`, `core_cmd_roster`,
  `core_cmd_thread`, `core_cmd_whoami`, `core_cmd_request_contacts`,
  `core_cmd_start_sync`, `core_cmd_poll_event`, `core_cmd_logout`, and the
  acknowledged full-wipe command `core_cmd_wipe`.
- Messaging: `core_cmd_send`, `core_cmd_send_attachment`,
  `core_cmd_send_reply`, `core_cmd_send_delete`, `core_cmd_send_reaction`,
  `core_cmd_send_receipt`, `core_cmd_send_message_edit`,
  `core_cmd_send_typing`, and `core_cmd_fetch_attachment`.
- Identity: `core_cmd_profile`.
- Native 1:1 calls: `core_cmd_call_start`, `core_cmd_call_accept`,
  `core_cmd_call_hangup`, and the RingRTC signaling bridge.
- Support: `core_last_error` and `core_free_string`.

Legacy raw-SDP call commands remain explicit failures; the supported path is
the native RingRTC API.

## Runtime data

The Swift app owns the presentation database at:

```text
~/Library/Application Support/CuztomSignal/messages.sqlite
```

The Rust/Signal store is at:

```text
~/Library/Application Support/CuztomSignal/signal.db
```

Downloaded media is stored below:

```text
~/Library/Caches/CuztomSignal/
```

Logout removes the Signal session, Swift message store, UUID/path mappings,
and downloaded media. User data and the local app bundle are gitignored.

## Verification status

- `cargo check`: passed.
- `cargo test --lib`: 9 tests passed.
- `cargo build --release`: passed.
- Full Xcode `swift test`: 52 tests passed.
- Manual verification: fresh QR link/resume, contacts/groups, name resolution,
  duplicate cleanup, message routing, and native 1:1 voice calling.

The remaining Rust-side blocker is group-call support: membership proof
retrieval, group/member RingRTC identity derivation, SFU HTTP delegate
support, and opaque group signaling.
