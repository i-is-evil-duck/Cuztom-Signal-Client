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
