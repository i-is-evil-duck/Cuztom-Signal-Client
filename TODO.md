# Remaining work

_Last updated: 2026-09-26_

**The call work is tracked in [`GROUP_CALLS.md`](GROUP_CALLS.md)** — current state,
a line-by-line comparison against `signalapp/Signal-Desktop`, deliberate
divergences, and an ordered A–F work list with acceptance criteria. This file
tracks everything else, and only summarises the call items so they are not lost
from this list.

`IMPLEMENTATION_PLAN.md` remains the detailed status matrix for the security and
storage work. `CALLS_PLAN.md` remains the chronological record of the call path.

## Calls: the short version

- [x] Group calls join Signal's production SFU — proof fetched, presented and
      redeemed natively, ICE connected, media keys and heartbeats flowing.
- [x] The cause of the silence found and fixed: a 64-byte member id where the SFU
      hashes 65, so no participant could resolve and RingRTC disabled audio
      outright. Pinned by a regression test.
- [x] **Group call audio inbound — working.** Confirmed against a real second
      client on 2026-09-26, after fixing two silent byte-length bugs: a member id
      one byte short, and a sender id one byte long.
- [ ] **Group call audio outbound — fix is in, unconfirmed.** RingRTC opens the
      audio input only from `set_audio_warmup`, which was never called, so the
      outgoing track carried nothing while incoming audio worked perfectly.
- [ ] **One live two-party call to confirm both directions at once.**
- [ ] Announce the call on join/leave with its `eraId` — the largest functional
      gap, since this client only ever receives rings.
- [ ] Mirror the OS microphone mute into live calls.
- [ ] Make the sync loop reconnect; today a dropped stream kills every later
      request, SFU included, which was observed killing a live call 12 s in.
- [ ] Stop 1:1 video pretending: `setLocalVideoEnabled` only flips a struct field
      and never reaches the core.

## P1 — Reliability and background delivery

- [ ] Fetch Signal's authenticated TURN relay list for 1:1. Group calls do not
      need it: RingRTC hardcodes an empty ICE server list for group calls and
      takes its configuration from the SFU join response.
- [ ] Investigate urgent-message delivery in the underlying Signal sender.
- [ ] Add APNs/VoIP push and a secure provider path for killed-app delivery.
- [ ] Add launch-at-login, reconnect policy, and background lifecycle handling.
- [ ] Add CallKit/system call UI and lock-screen call actions.
- [ ] Run a dedicated 500-message paging test and verify no gaps/duplicates.
- [ ] Run large attachment, oversized-file, and cache-eviction tests.

## P1 — Messaging and product features

- [ ] Group administration: create/rename, avatar, member management, roles, and
      leave group.
- [ ] Full video calling, group video, and multi-call handling.
- [ ] Disappearing-message timers.
- [ ] Cross-thread message search.
- [ ] Encrypted SQLite / keychain-backed protection for data at rest.
- [ ] Backup/restore and crash reporting.

## P2 — Release engineering

- [ ] Reproducible signed and notarized DMG release script.
- [ ] An update channel.
- [ ] Notarization licensing and privacy review.
- [x] A `#[no_mangle]` lost to an editing mistake no longer fails silently. It
      cost a build that would not start, reported as "rust core not found" --
      which points at the bundle rather than at the missing attribute. The parity
      check is now three-way: Rust to header, header back to Rust, and header to
      the Swift loader's `dlsym` names.
- [ ] `swift test` segfaults at process exit roughly 1 run in 4, *after* every
      test has passed. Pre-existing — reproduced at `e2608cb` with later work
      stashed. Harmless to the results, but it hides real failures and should be
      found.

## Recently completed

- [x] Native QR link/resume and websocket sync.
- [x] Stable 1:1/group routing and friendly name resolution.
- [x] SQLite duplicate suppression and startup cleanup.
- [x] Group sender-run chip grouping.
- [x] GIF/media rendering and attachment cache hardening.
- [x] Local message/call notifications.
- [x] Reactions, replies, edits, typing display, receipts, and link previews.
- [x] Native 1:1 RingRTC voice calls, verified between two real clients.
- [x] Idempotent logout/data wipe.
- [x] Group call banner with working microphone and camera controls.
- [x] Read receipts: a member who has read a message is no longer also listed as
      having only received it.
- [x] Call observability: the SFU peek, RingRTC's participant resolution, per
      device state, audio levels and WebRTC transport counters are all read and
      logged, which is what located the member-id bug.
- [x] **A group call mute now actually mutes.** It only set the heartbeat flag, so
      the call was told it was muted and transmitted anyway. RingRTC states that
      handling the track is the host's job; the 1:1 path always did, the group path
      did not.
- [x] **The group call banner lists everyone in the call**, each with their own
      mute state, presenting/screen-sharing, and whether they have been heard.
- [ ] **Receiving video and screen share are blocked on one thing**: there is no
      real `VideoSink`, so decoded frames are discarded. That is native interop,
      not Swift, and it gates everything else about video.
- [x] **Video sink written and wired in** (`rust-core/src/video.rs`). One slot per
      demux id, scaled before conversion, dropped rather than queued, 10 tests
      through the real native conversion. Supplying it is also what turns
      `enable_video_frame_content` on — with a null sink the native layer was never
      asked to produce frames at all.
- [x] **Frames cross to Swift and render.** ABI 9, poll-based, with the
      dimensions carried as out-parameters so a portrait frame is not drawn as a
      square. A tile per participant actually forwarding video, in the banner.
- [ ] **Receiving video has still never been seen working.** Everything up to the
      display is built and tested, and the SFU will not forward video until it has
      been asked — which has not been exercised. That is the next unknown, not
      more code.
