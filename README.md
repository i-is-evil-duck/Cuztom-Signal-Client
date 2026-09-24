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

### M1 — Link + 1:1 text (in progress)
- [x] `rust-core/`: presage `Manager` on a LocalSet worker thread, C ABI
  (`init` / `begin_link` / `poll_link` / `is_linked`), 3 `cargo test`s green
- [x] Swift `RustCoreService`: real `dlopen`+`dlsym` calls, string marshaling,
  offline `isLinkedAccount()` probe; `ChatViewModel` picks Live backend when
  the dylib is present, Mock otherwise (indicator in sidebar footer)
- [x] M1b roster/sync: `roster` (contacts+groups+recent msgs from sqlite),
  `whoami`, `request_contacts`, background `receive_messages` loop with
  control channel, `poll_event` queue, `send` (1:1 + groups); Swift decodes
  to `Conversation`/`ChatMessage` with stable ids, live pump into the store
- [x] 17+ `swift test`s (roster fixture mapping, stable ids, event decode),
  `cargo test` incl. roster/whoami rejection on fresh stores
- [x] UI phase gate (`starting → linking → linked | failed`): real QR from
  the `sgnl://` URL; failures show Retry + Continue-with-demo
- [x] Settings pane (app menu → Settings…): session/account, Log out
  (wipes keys, back to QR), Refresh now, Request contact sync, live
  diagnostics + log path (`~/Library/Logs/CuztomSignal/app.log`)
- [x] Resume linked sessions (`alreadyLinked` skips QR); demo removed —
  Live backend or an honest error
- [x] Release dylib (~18 MB) bundled next to the binary → Live backend
- [ ] Debug: sidebar empty on a live session — diagnostics + manual sync
  added to narrow it down (see Settings)

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

## Backlog — still to implement + test

Honest status as of the M1b sync build. Checked = done, open = not yet.

### History
- [x] Roster seed: last 100 messages/thread from the local store
- [x] `Load older messages` paging (`core_cmd_thread`, merged by stable key)
- [ ] Known limit: **Signal never syncs pre-link history** to a new linked
  device (protocol, not a bug). History accumulates from link time forward.
- [ ] Test: page a 500-message thread end-to-end, verify no dupes/gaps

### Attachments
- [x] Metadata in every message (`name/mime/size`); auto-download ≤25 MB on
  arrival into `~/Library/Caches/CuztomSignal`
- [x] Inline image rendering; file chips with Download/Reveal
- [x] On-demand fetch for roster-seeded rows (`core_cmd_fetch_attachment`)
- [ ] Send path for attachments (camera/file picker → CDN upload) — M2
- [ ] Test: 20 MB video round-trip; oversized file stays metadata-only;
  reveal-in-Finder from a downloaded row

### Plugins
- [x] `PluginHost` + `ChatPlugin` protocol (`/help`, unknown-command reply)
- [x] Built-in `InfoPlugin`: `/info /account /roster /diag /sync
  /thread <id> [n] /log` — read-only except `/sync`
- [x] Slash routing in the message field; replies are ephemeral (never stored/sent)
- [ ] `onMessage` hooks used by a real plugin (e.g. keyword notifier)
- [ ] Test: host with two plugins, command collision → first registered wins

### Correctness / polish backlog
- [ ] Reactions, replies, edits, disappearing timers, read receipts (M3)
- [ ] Calls via RingRTC (M4 — biggest milestone, separate module)
- [ ] Keychain-backed sqlite passphrase (currently unencrypted at rest)
- [ ] Notarized DMG + Sparkle updates (M5)
- [ ] Group admin ops (title/avatar/member add/remove)
- [ ] Message search across threads
- [ ] Notifications + badge + launch-at-login
- [ ] `onMessage` plugin fan-out wired into the receive path

### Test matrix
| Layer | Command | Status |
|---|---|---|
| Swift unit (Core) | `swift test` | 28 tests, green with fresh dylib |
| Rust unit (FFI) | `cargo test` (in `rust-core/`) | 3 tests, green |
| Live link + resume | manual, real phone | done (user-verified) |
| Roster + live receive | manual | done (6 convs, `queue_empty`) |
| 500-msg paging | manual | TODO |
| Attachment round-trip | manual | TODO |
| Logout → fresh QR | manual | TODO (Settings → Log out) |

## Commands

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product CuztomSignal
swift test            # Core unit tests (28)
cd rust-core && cargo test   # FFI unit tests (3)
```

> Full Xcode is required (SwiftUI + swift-testing macros don't expand under
> CLT alone). The runnable app is the `CuztomSignal` executable; the
> double-clickable `CuztomSignal.app` bundle is assembled by copying the
> binary + `rust-core/target/release/libcuztom_signal_core.dylib` into
> `CuztomSignal.app/Contents/MacOS/` and ad-hoc signing (bundle is
> gitignored, rebuilt locally).

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
