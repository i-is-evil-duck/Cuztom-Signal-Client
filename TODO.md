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
- [ ] **Group call audio: the member map does not resolve.** `remote_devices` is
      empty because the SFU's `opaqueUserId` values do not match
      `hex(sha256(member_id))` for the roster we supply, and an empty device list
      switches audio recording, outgoing media and playout off together. Next
      step is the new `resolved=N` figure in the peek log: 0 means the encrypted
      member ids differ from what the SFU hashed, `untried` means no roster
      reached RingRTC. This is the confirmed root cause of the silence.
