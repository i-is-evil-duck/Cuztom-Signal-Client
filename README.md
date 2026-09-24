# Cuztom Signal — native macOS Signal client

Lightweight SwiftUI Signal client for macOS. Linked-device only (phone stays primary).
Successor to `signal-bridge-V2` (Python + `signal-cli-rest-api` Docker bot that forwarded
Instagram reels to Signal groups). This repo is a clean, pure-Signal native app — no
Instagram code, no Java, no Docker at runtime.

Stack: **SwiftUI (Swift 6) + Rust core (`presage` + `libsignal`) + RingRTC (calls, M4)**.

> Legal: `libsignal` and `presage` are AGPLv3 — distributing binaries requires
> open-sourcing. Third-party clients are unsupported by Signal and risk rate-limits.
> No App Store; ship as notarized DMG + Sparkle updates.

## Code flow

```
SwiftUI Views (XcodeApp/Sources, full Xcode only)
  -> ChatViewModel (thin @Observable wrapper)
    -> ChatController (Sources/CuztomSignalCore, UI-agnostic, unit-tested)
      -> SignalService protocol (Sources/CuztomSignalCore/SignalService.swift)
        -> M0: MockSignalService (in-memory, deterministic)
        -> M1+: RustCoreService (dlopen -> rust-core/ presage Manager)
                  -> libsignal (crypto) + chat.signal.org (websocket)
                  -> MessageStore (actor, idempotent save) + SecretStore (Keychain)
```

Boundaries are protocol-shaped so M1 swaps the backend without touching UI:
`MessageStore` is already an actor with SQLite-compatible API; `SecretStoring`
has `InMemorySecretStore` (tests) and `KeychainSecretStore` (prod).

## Step-by-step plan

### M0 — Scaffold + mock chat (DONE)
- [x] SwiftPM `CuztomSignalCore` (models/store/service/mock/keychain) + `XcodeApp` SwiftUI split view
- [x] `ChatController` (UI-agnostic coordinator: link -> sync -> select -> send -> receive)
- [x] `RustCoreService` seam (dlopen FFI, fails loudly until Manager lands)
- [x] `MessageStore` extras (idempotent save, search, delete, totals)
- [x] 12 unit tests (`swift test`), Rust 1.98 toolchain installed
- Verify: `swift build`, `swift test`

### M1 — Link + 1:1 text (next)
1. Install Rust: `brew install rustup && rustup-init`, add `aarch64-apple-darwin` target.
   Plus `brew install protobuf` (`protoc` needed by `spqr` build script — verified blocker, see `rust-core/README.md`).
2. Wire `rust-core/src/lib.rs`: `presage::Manager::link_secondary_device` -> real QR URI out of `link_device_qr`, `SqliteStore` at `~/Library/Application Support/CuztomSignal/signal.db`.
3. Swift `RustCoreService: SignalService` via C header + `core_free_string`; replace `MockSignalService` in `ChatViewModel`.
4. Persist identity in `KeychainSecretStore`; contacts sync into `MessageStore`.
5. Tests: link round-trip against `presage-cli` test account, send/receive text to self, offline-reconnect.
6. Verify: link a test number, send 1:1 text both directions, restart app (session persists).

### M2 — Groups + attachments
1. GroupsV2 (`zkgroup`) sync: member list, title/avatar, admin flags.
2. Attachment CDN up/down with progress; cap 100 MB (same as bridge default `MAX_ATTACHMENT_MB`); thumbnails in list.
3. Swap `MessageStore` backend to SQLite (GRDB or `presage-store-sqlite`); migration test from M0 in-memory snapshot.
4. Tests: group send/receive, 25 MB video round-trip, quota of bridge (`DAILY_SEND_LIMIT`) not needed — pure client sends immediately.

### M3 — Reactions / replies / edits / disappearing / receipts
1. Message modifiers pipeline (idempotent apply, tombstones).
2. Disappearing-message timers per conversation.
3. Read/delivery receipts reflected in `MessageStatus`.
4. Tests: out-of-order delivery, duplicate suppression, timer expiry.

### M4 — Calls (RingRTC, heaviest milestone)
1. Vendor `signalapp/ringrtc`, mic/camera/screen permissions, device picker.
2. 1:1 + group call signaling over the existing websocket; CallKit-style macOS UI.
3. Tests: mocked signaling handshake, no-media call setup/teardown, permission-denied path.

### M5 — Ship
Notarized DMG, Sparkle updater, crash reports, menu-bar badge, notifications, launch-at-login (websocket keepalive), docs.

## Tests

| Layer | Where | Run |
|---|---|---|
| Core unit (models, store, controller flow, mock link/send, secrets, rust seam) | `Tests/CuztomSignalCoreTests` | `swift test` |
| UI smoke (link -> select thread -> send) | `XcodeApp` previews + manual | open in Xcode, run |
| Rust core (M1+: link, sync, round-trip) | `rust-core/` | `cargo test` (needs rustup) |
| Integration (M1+: two test devices) | manual + `presage-cli` | `cargo run -p presage-cli -- link-device`, `receive` |

Current status: `swift test` passes 12/12 on CLT (no Xcode required for Core).
Rust 1.98 via rustup; `cargo fetch` validating `presage` git deps. Xcode
still downloading — `XcodeApp/` compiles only under full Xcode (SwiftUI macros).

## Commands

```bash
swift build
swift test
# M1+ (after installing Rust):
# cd rust-core && cargo build && ./build-xcframework.sh
```

> Note: `XcodeApp/` (SwiftUI) requires full Xcode — Command Line Tools alone
> can't expand SwiftUI macros (`StateMacro` plugin missing), so it is kept
> out of `Package.swift` until you open it in Xcode. `swift build/test`
> covers `CuztomSignalCore` only.

## Repo layout

```
Package.swift                    SwiftPM (Core + Tests; builds on CLT)
Sources/CuztomSignalCore/        Models, SignalService protocol, ChatController,
                                 MessageStore actor, SecretStore (memory + Keychain),
                                 MockSignalService, RustCoreService (dlopen seam)
XcodeApp/Sources/                @main App, ChatViewModel (thin wrapper), split-view UI
                                 (full Xcode only; SwiftUI macros don't load under CLT)
Tests/CuztomSignalCoreTests/     12 tests (swift-testing): CoreTests + ControllerTests
rust-core/                       Cargo crate stub -> presage Manager + C ABI (M1)
```

## Relation to signal-bridge-V2

| | bridge-V2 | Cuztom Signal |
|---|---|---|
| Runtime | Docker, Java `signal-cli`, Python poller | Native binary, no Docker/Java |
| Auth | `GET /v1/qrcodelink`, `data/signal/` bind mount | Native QR via presage, Keychain + `~/Library` |
| Send | `POST /v2/send` + `base64_attachments` | libsignal encrypt + websocket + CDN |
| Store | `/state/*.json`, Docker volumes | SQLite + Keychain |
| Scope | IG-reel forwarder | Full chat client (+ calls M4) |
