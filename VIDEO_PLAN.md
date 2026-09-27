# Video and screen share: research and implementation plan

_2026-09-26. Read together with [`GROUP_CALLS.md`](GROUP_CALLS.md); the work list
there defers to this document for anything about video._

## The headline

Receiving video and receiving a screen share are the **same work**. A shared
screen arrives as a video stream, so there is no separate screen-share path to
build, negotiate or test. That is worth stating first because "screen share" sounds
like a second feature and is not.

The good news: **no vendor patch is needed at all.** The bad news, for the
record, is that I initially concluded one was — see the correction below.

## Correction: the first pass of this research was wrong

I initially wrote that reading pixels out of a received frame needed a vendor
patch, on the grounds that the public API on `VideoFrame` could only push frames
*in*. That came from reading `webrtc/ffi/media.rs` and stopping there.

It is wrong. `webrtc/media.rs` already exposes, unmodified:

```rust
pub fn to_rgba(&self, rgba_buffer: &mut [u8]) -> bool
pub fn as_i420(&self) -> Option<&[u8]>
pub fn scale(&self, width: u32, height: u32) -> Self
pub fn apply_rotation(self) -> Self
// and on VideoTrack:
pub fn set_enabled(&self, enabled: bool)
pub fn set_content_hint(&self, is_screenshare: bool)
```

Everything the plan needs, including a screen-share content hint, already exists
upstream. I wrote the patch, found it collided with an existing `to_rgba`, and
reverted it. `vendor/ringrtc` now differs from upstream only by the two patches it
already had.

The lesson is the one worth keeping: I searched the FFI layer for a capability and
concluded it was absent from the crate, having searched one layer of it. A negative
result from a grep is only as good as the search.

## What the research found

Verified in the vendored RingRTC at
`rust-core/vendor/ringrtc/src/rust/src`, and against
`signalapp/Signal-Desktop` and its shipped `app.asar`.

### 1. Frame delivery switches on automatically when a sink exists

`core/group_call.rs:5137`:

```rust
let enable_video_frame_content = incoming_video_sink.is_some();
```

That value is passed to the native peer connection observer as
`enable_video_frame_content` (`group_call.rs:5147`), alongside
`enable_video_frame_event`, which is hardcoded `true`. So today, with
`NullVideoSink` in `init_calls`, **the native layer is not producing frame content
at all** — not discarding it, never producing it.

Supplying a real sink flips it on. There is no flag to set and nothing else to
configure. This is the single cheapest thing in the whole plan.

### 2. The sink receives frames keyed by demux id

```rust
pub trait VideoSink: Sync + Send {
    fn on_video_frame(&self, demux_id: DemuxId, frame: VideoFrame);
    fn box_clone(&self) -> Box<dyn VideoSink>;
}
```

`demux_id` is what makes a grid or a screen-share tile possible: it identifies the
participant, and RingRTC already maintains the demux-id-to-user-id mapping that
now works. So a frame arriving on demux id *N* can be attributed to a person.

### 3. Pixels are readable, and already were

`VideoFrame` wraps an opaque native buffer, which looks opaque from the outside.
It is not:

```rust
pub fn to_rgba(&self, rgba_buffer: &mut [u8]) -> bool
```

`to_rgba` converts in place into a caller-supplied buffer and reports success.
With `as_i420`, `scale` and `apply_rotation` also present, a host has everything
needed to receive, resize, convert and display a frame, and none of it required
touching the vendored crate.

`Rust_convertVideoFrameBufferToRgba` is confirmed present in the native library
this build links (`nm` on the prebuilt archive), so the symbol resolves.

### 4. Signal Desktop moves pixels too — there is no native view path

Checked properly this time, and the answer turned out to be the reference
implementation of the sink rather than a shortcut. Signal Desktop on macOS is
Electron, and it does not hand ringrtc a view either:

- `GroupCall.getVideoSource(remoteDemuxId)` returns a
  `GroupCallVideoFrameSource` per remote participant.
- The UI creates a `<canvas>` per participant, takes `getContext('2d')`, and calls
  `source.receiveVideoFrame(buffer, maxWidth, maxHeight)`.
- That reaches `cm_receiveGroupCallVideoFrame`, which hands the pixels to the
  native layer.

So the flow is native → JS pixels → canvas → paint. **Electron is copying pixels
too**, exactly as a native host must, and its `HTMLVideoElement` is not something
a native app can hand over. There is no `set_local_preview` and no FFI taking a
view, window or layer pointer.

Two things worth taking from Signal's implementation rather than reinventing: one
canvas per remote demux id, and dropped frames rather than a queue. Both are in the
architecture below.

### 5. The decoder will stall if a frame is held

`webrtc/media.rs:327`, on the sink trait:

> Warning: this video frame's output buffer is shared with a video decoder, and so
> must quickly be dropped (by copying it and dropping the original) or the video
> decoder will soon stall and video will be choppy.

This dictates the architecture. Work must happen on the sink callback and must not
wait on the UI thread. A design where Swift polls a shared buffer on a timer is
wrong, because the copy would either happen on the wrong thread or not at all.

### 6. Screen share and camera are not the same, even though they arrive alike

Both arrive as video on a demux id, but the SFU reports them as separate heartbeat
fields — `sharing_screen` and `presenting` — and they have opposite profiles: a
share is typically 30fps, silent, and much larger than any camera. Both are already
surfaced per participant in the roster. The plan therefore downscales before
converting (§ step 4), because converting a 1080p frame to RGBA is 8 MB of
copying at 30 fps.

## What the tests established, and one more wrong turn

The sink is written and its behaviour is pinned by 10 tests that go through the
real native conversion, not a stand-in — `VideoFrame::copy_from_slice` builds a
genuine frame from known bytes, the sink consumes it, and the caller reads back
what was published.

Three things came out of writing them, and the second is another conclusion I got
wrong on the first attempt:

- **The round trip is lossy.** `VideoFrame::copy_from_slice` takes RGBA in and
  `to_rgba` gives RGBA back, but the native frame buffer is chroma subsampled, so
  the bytes are not identical: a flat `[40, 90, 200, 255]` comes back
  `[39, 90, 197, 255]`. Consumers must treat these as display-ready pixels and
  never compare them for equality.
- **I first read the output as BGRA.** A 4x3 gradient comes back with red and blue
  apparently swapped, which is exactly what a BGRA buffer looks like. It was not
  swapped — the two channels were within a few counts of each other on an image
  too small for subsampling to be lossless. Two wide-separated flat blocks, sampled
  away from the boundary between them, prove the order properly. **Calibrate on
  something big and flat before believing anything read off a small gradient.**
- **The native layer aborts the process on a degenerate frame.**
  `VideoFrame::copy_from_slice(0, 0, …)` does not return an error, it trips
  `Check failed: width > 0` in `video_frame_buffer.cc` and takes the process with
  it. The guard in `accept_frame` is cheap and fail-closed, but in practice the
  native layer will not hand us a zero-sized frame in the first place. Worth
  knowing before anything is allowed to construct frames here.

## Architecture

```
native decoder
  └─ on_video_frame(demux_id, VideoFrame)      [sink callback thread]
       ├─ downscale if larger than we render   Rust_scaleVideoFrameBuffer
       ├─ convert to RGBA                      Rust_convertVideoFrameBufferToRgba
       ├─ copy into a preallocated slot        the only safe moment to copy
       ├─ publish {demux_id, width, height, rgba, seq}
       └─ return                               frame dropped immediately
Swift main thread
  └─ drains published slots, drops stale ones  never blocks the sink
  └─ RGBA → CVPixelBuffer → CALayer.contents
```

Two decisions worth defending:

- **Publish, don't call across the boundary.** A `@convention(c)` callback into
  Swift would work, but it puts an unknown consumer on the decoder's thread. A
  bounded publish means a slow or wedged UI can cost frames but cannot stall the
  decoder, and that is the failure the warning above is about.
- **One slot per demux id, overwritten, never queued.** Video is not a stream of
  events; the newest frame is the only one worth having. Queueing frames is how you
  build latency. A caller that cannot keep up drops frames, which is correct.

## Steps

Each step is independently verifiable, and the order is dependency order.

### Step 1 — **Dropped.** No vendor patch is required

The capability was already upstream; see the correction at the top. What remains
here is only buffer sizing, which is arithmetic: `width * height * 4`, guarded so a
mismatch drops the frame rather than overrunning anything.

### Step 2 — The host sink

A `CuztomVideoSink` implementing `VideoSink`, holding per-demux-id slots. Writes
the downscaled RGBA into a preallocated buffer and publishes a monotonically
increasing sequence number. Replaces `NullVideoSink` in `init_calls`.

*Done when:* a test feeds it a synthetic frame and asserts the published slot has
the right dimensions and the newer sequence number replaces the older; and that a
second demux id gets its own slot.

*Note:* this is the step that turns `enable_video_frame_content` on, so it is also
the point at which the native layer starts doing real work. Watch CPU.

### Step 3 — Getting frames to Swift — **done**

Five C entry points: frame size, take frame, stats, forget one, forget all. ABI 9.

Two design points worth keeping:

- **Not routed through the command roundtrip.** The frames live behind one mutex,
  there is no actor to reach, and a caller-supplied buffer pointer has no business
  travelling through a channel to another thread. Reading straight from the sink
  keeps the pointer valid for exactly the duration of the call.
- **The caller drives by sequence number, and reads are not consuming.** Asking
  twice with the same sequence returns the same frame twice. Consuming on read
  would lose the frame for any caller that missed the first response — a bug that
  would only ever appear under load.

**The dimensions cross the boundary as out-parameters**, and getting that wrong
was the first attempt: a byte count does not say whether a frame is 640x360 or
360x640, and drawing it with the wrong shape stretches somebody's face. Both are
cleared before anything else, so a zero return cannot leave a caller holding the
previous frame's shape.

*Done when:* satisfied. 12 tests, each confirmed to fail when the behaviour is
reverted, including that a short buffer is refused rather than truncated, that a
null pointer is refused, and that a miss clears the dimensions.

### A hazard worth writing down

`VideoFrame::copy_from_slice(w, h, format, buffer)` takes a `&[u8]` and hands only
its **pointer** to the native library, which then reads `w * h * 4` bytes with no
length to check against. A short slice is an out-of-bounds read — not an error,
not a panic, just a frame full of whatever followed it in memory. It cost an hour
here, and it is recorded in `vendor/ringrtc/CHANGELOG-VENDOR.md`.

### Step 4 — Rendering in Swift — **done, unverified against a real call**

`VideoFrameImage` (RGBA → `CGImage`) and `RemoteVideoFeed` (poll → draw), with
`RemoteVideoTile` in the banner. A horizontal strip, one tile per participant the
SFU reports as forwarding video, each keeping its own aspect ratio so nobody is
squashed to fit a fixed box.

`CGImage` rather than a `CVPixelBuffer` and `AVSampleBufferDisplayLayer`. The
sample-buffer layer is the right tool for a continuous video stream; here the
frames arrive already dropped and already at most 720px, and all that is wanted is
something a layer can draw. `CGImage` is immutable, so one is built per frame —
about 2 MB of extra copying at video rate, against a decoder doing far more work
on the same frame. Not worth a data provider to avoid.

Three things found by writing it:

- **`CGImageAlphaInfo.last` is rejected** for 8-bit RGB device colour. `CGContext`
  returns nil and the frame silently disappears — no error, just no picture.
  `noneSkipLast` is the right one anyway: straight alpha, so CoreGraphics does not
  divide colour by an alpha that is already 255. Correct by construction rather
  than correct by accident.
- **The feeds are derived, not imperatively refreshed.** The first attempt had a
  `refreshGroupCallVideoFeeds()` called from a view body, which does not compile
  and should not. `groupCallVideoFeeds` is now computed from the call's own
  participant list, so it cannot be stale relative to the roster beside it.
- **A tile is only made for a participant the SFU says is forwarding video** and
  has told us a height. A tile for someone sending nothing is a black rectangle,
  which reads as broken video rather than as no video.

*Done when:* satisfied as far as it can be without a call. 4 tests on the
conversion, including that a frame which cannot exist yields no image rather than
a blank one, and that the caller's buffer is not written to. **What remains
unverified is the only thing that matters: nobody has seen a real remote frame go
through this.** That is step 6's problem too — the SFU will not forward video
until it has been asked, and that has not been exercised.

### Step 5 — Outgoing video and the camera

Permission is already correct: requested only when the camera is turned on, and a
refusal leaves it off without ending the call. What is missing is the capture half
— `create_outgoing_video_source` is called and the source is left alone.

The same class of bug as the microphone is the thing to check first: RingRTC says
outright that handling the outgoing track is the host's job, and that is exactly
where the group audio mute was wrong. Verify a muted camera actually stops sending
rather than only reporting that it has.

*Done when:* the other side sees our camera, and muting it actually stops the
video.

### Step 6 — Requesting video

The SFU only forwards video once asked, and RingRTC drives that from the peer's
allocated height. It should follow automatically once steps 1–4 work, since
`server_allocated_height` is already arriving in the roster. **Unverified, and
listed rather than assumed** — a plausible mechanism that has not been exercised is
not a working one.

## Risks

| Risk | Why it matters | Mitigation |
|---|---|---|
| Copy cost | RGBA at 1080p is 8 MB/frame; 30 fps is 250 MB/s | Downscale before converting; cap the render size |
| Decoder stall | Holding a frame stalls decoding | Copy on the sink thread, drop immediately, never block |
| Frame lifetime | The buffer belongs to the decoder | One preallocated slot per participant, overwritten |
| Unbounded memory | A large call times a large frame size times a participant count | Hard cap on slot dimensions; drop rather than grow |
| Native instability | `to_rgba` is a new call into C++ we do not own | Wrapped, tested round-trip, and failure returns `false` rather than panicking |

## What is deliberately not in this plan

- **A call screen.** A banner cannot host video. The screen is a prerequisite for a
  good result and is tracked separately in `GROUP_CALLS.md` §4D. This plan gets
  frames onto a layer; where they live is that decision.
- **A local preview.** Follows from step 5 and is cheap once the outgoing track is
  real, but it is not what unblocks receiving.
- **Adaptive resolution or simulcast.** RingRTC negotiates some of this already.
  Do not build it before anything renders at all.
