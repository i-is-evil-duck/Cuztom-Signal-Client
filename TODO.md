# Remaining work

_Last updated: 2026-09-24_

The original polish/calls checklist has been completed substantially. This
file now tracks the remaining product and reliability work rather than
re-listing features that are already implemented.

## P0 — Group calls

- [ ] Retrieve and validate Signal external group membership proofs.
- [ ] Derive RingRTC group IDs and accepted-member identities from the group
  master key/membership ciphertext.
- [ ] Implement RingRTC's HTTP delegate for SFU requests and responses.
- [ ] Add opaque group-call signaling without changing the 1:1 path.
- [ ] Add separate Rust FFI commands and Swift group-call state/UI.
- [ ] Verify with two linked/native clients before enabling the group-call
  button.

## P1 — Reliability and background delivery

- [ ] Fetch Signal's authenticated TURN relay list.
- [ ] Investigate urgent-message delivery in the underlying Signal sender.
- [ ] Add APNs/VoIP push and a secure provider path for killed-app delivery.
- [ ] Add launch-at-login, reconnect policy, and background lifecycle handling.
- [ ] Add CallKit/system call UI and lock-screen call actions.
- [ ] Run a dedicated 500-message paging test and verify no gaps/duplicates.
- [ ] Run large attachment, oversized-file, and cache-eviction tests.

## P1 — Messaging/product features

- [ ] Group administration: create/rename, avatar, member management, roles,
  and leave group.
- [ ] Full video calling, group video, and multi-call handling.
- [ ] Disappearing-message timers.
- [ ] Cross-thread message search.
- [ ] Encrypted SQLite/keychain-backed protection for data at rest.
- [ ] Backup/restore and crash reporting.

## P2 — Release engineering

- [ ] Reproducible signed/notarized DMG release script.
- [ ] Sparkle or another signed update channel.
- [ ] App Store/notarization licensing and privacy review.
- [ ] macOS CI for full Xcode Swift tests and the RingRTC Rust build.

## Recently completed

- [x] Native QR link/resume and websocket sync.
- [x] Stable 1:1/group routing and friendly name resolution.
- [x] SQLite duplicate suppression and startup cleanup.
- [x] Group sender-run chip grouping.
- [x] GIF/media rendering and attachment cache hardening.
- [x] Local message/call notifications.
- [x] Reactions, replies, edits, typing display, receipts, and link previews.
- [x] Native 1:1 RingRTC voice calls.
- [x] Idempotent logout/data wipe.

See `IMPLEMENTATION_PLAN.md` for the detailed status matrix and
`CALLS_PLAN.md` for the native call boundary.

## Group call audio: measurement is missing, not media

- [ ] The native WebRTC layer reports no audio levels and no RTC stats in this
      build (`Rust_getAudioLevels` returns zero for both captured and received;
      `RtcStatsReportComplete` never fires). Until that is resolved, "is audio
      arriving" can only be inferred from `RemoteDeviceState`, which is indirect.
      Worth raising upstream or vendoring the native side.
- [ ] The peer dropped ~1.4 s after unmuting video. Unresolved: an unrelated drop,
      or a video stream this client cannot produce properly. The camera work makes
      it testable; it has not been tested yet.
- [ ] `swift test` segfaults at process exit roughly 1 run in 4, *after* every
      test has passed. Pre-existing — reproduced at `e2608cb` with this session's
      changes stashed. Teardown, not a test failure, but it hides real failures
      and should be found.
- [x] **Group call audio: the member map did not resolve.** Cause found and
      fixed: the member id was 64 bytes where the SFU hashes 65. zkgroup's
      `UuidCiphertext` carries a leading `ReservedByte` that has to be sent;
      Signal's own client passes the whole serialization. Pinned by
      `a_member_id_keeps_the_reserved_byte_the_sfu_hashes`. Still needs one live
      call to confirm `resolved=` goes above 0 and audio appears.
- [ ] **System microphone mute is not observed.** Signal subscribes to
      `muteStateChange` and calls `setOutgoingAudioMuted` on every live call when
      the OS reports the mic muted. Nothing here watches the system state, so a
      hardware/keyboard mic mute would present as a call that is mysteriously
      muted with no user action taken. Worth adding before chasing any further
      "the mic is muted" report.

## Group call: gaps found by diffing against signalapp/Signal-Desktop

Read against `ts/services/calling.preload.ts` and
`ts/calling/VideoSupport.preload.ts`.

- [ ] **No group call update message on join or leave.** When the local device
      reaches `Joined`, Signal sends a `GroupCallUpdate` carrying the call's
      `eraId` (`#onGroupCallJoined` ->
      `ts/jobs/helpers/sendGroupCallUpdate.preload.ts`). That is how other
      members' devices learn a call is happening, and it is what makes a call
      discoverable by someone who is not being rung. This client never announces;
      it only ever receives rings. A member who is not ringing us has no way to
      know the call exists.
- [ ] **No peeking before joining.** `peekGroupCall()` fetches a proof and peeks
      without connecting, so the lobby can show the participant count, whether the
      call is full (`maxDevices`), who is ringing, and whether joining is even
      possible. This client joins blind and only learns the participant list once
      it is already in the call.
- [ ] **A denied microphone permission cancels the call here.** Signal logs
      "Permissions were denied, but allow joining group call" and joins anyway.
      This client refuses to start. That is a deliberate difference and arguably
      the safer one, but it is a divergence and should be a decision rather than
      an accident.
- [ ] **Audio devices are selected once, at init.** Signal runs
      `#startDeviceReselectionTimer()` so a device plugged in mid-call is picked
      up. This client calls `select_default_audio_devices` a single time with a
      5s deadline.
- [ ] No global mute state. Signal keeps `muteStateChange` and mirrors it into
      every call; see the system-mic-mute item above.
