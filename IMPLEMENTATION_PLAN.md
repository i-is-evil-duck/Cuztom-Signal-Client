# Implementation status and next steps

_Last updated: 2026-09-24_

This document reflects the current `main` working tree after the native-call
and messaging-hardening pass. The project is now a working linked-device
client; the remaining work is primarily group calls, offline delivery,
group administration, and release hardening.

## Completed work

### Core messaging and identity

- [x] Native QR linking and linked-session resume.
- [x] Native Signal websocket receive loop and contact/groups sync.
- [x] Canonical 1:1 and GroupsV2 thread IDs.
- [x] GroupsV2 `masterKey`/`revision` context on outgoing group messages.
- [x] Self/Note to Self labeling and stable canonical thread routing.
- [x] Friendly contact and group names, sender hints, initials, and group
  member profile-key fallback lookup.
- [x] Contact sync refresh on the authoritative `contacts_synced` event.
- [x] Resolved profile names are preserved when a later roster refresh has
  only a blank/`Unknown` value.

### Storage and duplicate suppression

- [x] SQLite/GRDB production message store with in-memory test store.
- [x] Stable message identity based on thread, sender, and client/store
  timestamp; server-clock differences no longer create a second UUID.
- [x] UUID migration aliases for the previous server-clock key format.
- [x] Logical deduplication in both in-memory and SQLite stores.
- [x] Attachment-only message normalization (`""` vs `[attachment]`).
- [x] Startup migration removes old duplicate rows and empty control-envelope
  rows.
- [x] Unread counts and notifications are not incremented by replayed rows.
- [x] Startup reentrancy guard prevents multiple service/controller instances.
- [x] Logout clears Rust state, Swift SQLite state, caches, attachments, UUID
  mappings, path mappings, and keychain material.

### Messaging features

- [x] 1:1 and group text sending/receiving.
- [x] Attachments: upload, metadata-only history rows, on-demand download,
  image/video rendering, animated GIFs, Reveal in Finder, and stable cache
  paths per attachment index.
- [x] Reactions.
- [x] Replies and message edits.
- [x] Delete for me and delete for everyone.
- [x] Incoming typing indicators. Outgoing typing remains intentionally
  disabled because the current presage sender path is unsupported.
- [x] Read/delivery receipt settings, sending, and display.
- [x] Link previews.
- [x] Message list scrolls to newest content on send/receive.
- [x] Group sender chips only on the first message in a contiguous sender run.

### macOS integration

- [x] Native local notifications for newly received messages.
- [x] Native local notifications for incoming calls, with duplicate
  suppression and cancellation on answer/decline/hangup.
- [x] Notification enable/disable setting.
- [x] Incoming message notifications are suppressed for the currently viewed
  conversation while the app is active.
- [x] Ad-hoc signed local app bundle with the rebuilt native dylib.

### Native 1:1 calls

- [x] RingRTC native/prebuilt-WebRTC foundation.
- [x] Native offer/answer/ICE/hangup/busy Signal signaling.
- [x] 1:1 voice call state machine, microphone permission, mute, elapsed
  timer, and incoming/outgoing UI.
- [x] Call state and signaling bridge survives the current 1:1 path.

## Current validation

- Swift Testing: **38 tests passed**.
- Rust library tests: **6 tests passed**.
- `cargo check`: passed.
- `cargo build --release`: passed.
- `swift build --product CuztomSignal`: passed with full Xcode.
- Local app bundle rebuilt, signed, and smoke-tested against a fresh link.
- Fresh-reset verification confirmed contact/group names render and old
  duplicate/control rows do not reappear.

## Open work, in priority order

### P0 — Group calls

Do not enable the group-call button until all of the following are complete:

1. Retrieve and validate Signal external group membership proofs.
2. Derive RingRTC group and accepted-member identities from the group master
   key and membership ciphertext.
3. Implement RingRTC's HTTP delegate for SFU requests/responses.
4. Add opaque group-call signaling without changing the working 1:1 path.
5. Add separate Rust FFI commands and Swift group-call lifecycle/UI.
6. Verify with two linked/native clients before shipping the button.

### P1 — Reliability and background delivery

- Fetch Signal's authenticated TURN relay list.
- Expose/support urgent-message signaling where the underlying sender permits
  it.
- Add APNs registration and encrypted provider-backed ordinary/VoIP delivery.
- Add launch-at-login, reconnect policy, and background lifecycle handling.
- Add CallKit/system call UI and lock-screen actions for incoming calls.
- Add a true 500-message paging test and larger attachment/limit tests.

### P1 — Product features

- Group administration: create/rename, avatar, member management, roles, and
  leave group.
- Full video calling, group video, multi-call handling, and device selection.
- Disappearing-message timers.
- Cross-thread message search.
- Encrypted SQLite/keychain-backed database protection at rest.
- Backup/restore and crash reporting.

### P2 — Release engineering

- Signed and notarized DMG with a reproducible release script.
- Sparkle or another signed update channel.
- App Store/notarization licensing review and user-facing privacy disclosures.
- CI running the full Xcode Swift tests and RingRTC Rust build on macOS arm64.

## Definition of done for group calls

A group-call MVP is not complete until membership proof retrieval, SFU HTTP
request/response handling, opaque group signaling, accepted-member key
mapping, and a two-client native test all pass. The existing 1:1 call path must
remain green throughout the work.
