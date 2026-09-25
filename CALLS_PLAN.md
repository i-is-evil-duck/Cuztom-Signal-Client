# Call Implementation Plan (RingRTC native, macOS)

## Goal
Real 1:1 voice calls in the existing Rust-core + SwiftUI app. No `signal-cli`
subprocess and no virtual-audio-device bridge. Group calls are now a staged
follow-up; the current release keeps the working 1:1 path isolated while the
Signal group-call transport and SFU bootstrap are implemented.

## Foundation — complete
- `ringrtc` builds with `features = ["native", "prebuilt_webrtc"]`.
- Signal's prebuilt `libwebrtc.a` is fetched and linked for macOS arm64.
- `scripts/grealpath` removes the GNU `realpath -e` build dependency.
- The dylib links `CoreAudio`, `AudioToolbox`, `AudioUnit`, and `IOKit`.
- `sync::call_signal_part` lifts `CallMessage` envelopes out of the receive
  stream, including all ICE updates in one event.

## Phase A — Rust RingRTC platform layer — complete
- Reuse ringrtc's public `NativePlatform` rather than reimplementing its large
  `Platform` trait.
- Implement `SignalingSender` to turn RingRTC offer/answer/ICE/hangup/busy
  messages into Signal `CallMessage` protobufs.
- Implement `CallStateHandler` and forward `proceed` actions to the core loop.
- Initialize one `PeerConnectionFactory`, CoreAudio input/output selection,
  audio track, and `CallManager` per process.
- Set the local device id and self UUID from the linked registration.

## Phase B — RingRTC ↔ libsignal bridge — complete
- RingRTC's synchronous callback puts a `PendingCallSignal` on a thread-safe
  unbounded channel.
- A persistent bridge task forwards it to the current tokio `LocalSet` control
  loop, which performs the asynchronous `Manager::send_message`; queued work
  is discarded while logged out so it cannot cross account sessions.
- RingRTC is notified with `message_sent` or `message_send_failure` after the
  real send, so its signaling queue cannot stall or race ahead.
- Inbound offer/answer/ICE/hangup/busy events are fed to RingRTC on the core
  loop. ACI and PNI identity keys are looked up from the protocol store and
  passed as raw 32-byte RingRTC keys.

## Phase C — C ABI / FFI — complete
- `core_cmd_call_start(thread, media_type) -> u64` (`u64::MAX` on error).
- `core_cmd_call_accept(call_id) -> i32`.
- `core_cmd_call_hangup() -> i32`.
- Legacy raw-SDP commands now fail explicitly instead of silently pretending
  to send a call.

## Phase D — Swift integration — complete
- `RustCoreService` resolves the native symbols and exposes start/accept/hangup.
- `onCallSignal` and `onCallState` callbacks feed the rewritten `CallController`.
- Outgoing/incoming/connecting/active/ended state is mapped to the existing
  SwiftUI call overlays; call history is updated once per call.
- The fake SDP generator is removed.
- Microphone permission is requested through AVFoundation before placing or
  answering a call.
- `NSMicrophoneUsageDescription` is present in the app bundle.

## Message and identity hardening — complete
- Group sends now include GroupsV2 `masterKey`/`revision` context so remote
  Signal clients file them in the group instead of a sender DM.
- Conversation selection is generation-guarded and Send captures its target
  before asynchronous history work can complete.
- Message lists scroll to the newest message on send/receive.
- Friendly names and initials are used for group senders, receipts, calls, and
  account labels; the logged-in account is labeled `Note to Self`/`You`.
- Logout/data wipe is idempotent and clears Rust state, Swift state, caches,
  attachments, UUID mappings, and keychain material.

## Phase E — Verification
- `cargo build --release` passes.
- `swift build --product CuztomSignal` passes with the full Xcode toolchain.
- The new dylib and app executable are deployed to `CuztomSignal.app`.
- App startup smoke test reaches linked sync and logs
  `native RingRTC calls initialized`.
- FFI protobuf/build smoke tests pass without a linked account.
- Real 1:1 voice calls have been manually verified with two-way audio and
  microphone capture; group calls remain a staged follow-up.

## Known limitations / follow-ups
- ICE currently uses public STUN servers; Signal's authenticated TURN relay
  list is not yet fetched from the server. The presage/libsignal websocket
  sender also has no exposed urgent-message flag, so calls to a fully offline
  phone may not produce a push notification.
- Ringtone/ringback audio and system audio-route selection are not implemented.
- Group/video calls, multi-call handling, and persistent call history remain
  follow-up work. Group-call transport, membership proof, and SFU HTTP support
  are intentionally not enabled in this release.
