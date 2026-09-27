//! Receiving video and screen share.
//!
//! Both arrive here. A shared screen is a video stream on a demux id like any
//! other, so there is no separate screen-share path to build, negotiate or test —
//! only a different content hint going out and a different label coming back.
//!
//! # The shape of this, and why
//!
//! RingRTC calls [`VideoSink::on_video_frame`] on its decoder thread, and warns
//! about what happens if a frame is held:
//!
//! > Warning: this video frame's output buffer is shared with a video decoder, and
//! > so must quickly be dropped (by copying it and dropping the original) or the
//! > video decoder will soon stall and video will be choppy.
//!
//! So everything happens on that thread and nothing waits: convert, copy, publish,
//! return. The consumer is a slot rather than a queue, because video is not a
//! stream of events — the newest frame is the only one worth having, and queueing
//! frames is how you build latency. A consumer that cannot keep up drops frames,
//! which is the correct outcome.
//!
//! One slot per demux id, so a participant's frames never overwrite another's and
//! a caller can ask for one participant without disturbing the rest.
//!
//! Signal Desktop's Electron build does the same copy in JavaScript, into a
//! `<canvas>` per remote demux id, and likewise drops rather than queues. There is
//! no path in which ringrtc renders into a host view, so a native host moves the
//! pixels itself and that is not a workaround — it is the design.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use ringrtc::lite::sfu::DemuxId;
use ringrtc::webrtc::media::{VideoFrame, VideoSink};

/// Longest edge, in pixels, of a frame this module will convert.
///
/// Bounds memory per participant to about 3.7 MB and bounds the copy on the
/// decoder's thread, which is the thread we must not stall. A 1080p share scaled
/// to this is indistinguishable at banner or single-tile size, and RingRTC is
/// already scaling down to whatever height the SFU allocated for the device.
const MAX_EDGE: u32 = 720;

/// One participant's most recent frame.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct VideoSlot {
    pub width: u32,
    pub height: u32,
    /// Bumped on every accepted frame. A consumer passes the last sequence it saw
    /// and gets the frame only if this has moved, so a redraw that happens to
    /// find nothing new does not re-convert or re-upload the same pixels.
    pub sequence: u64,
    /// Tightly packed **RGBA**, `width * height * 4` bytes, as
    /// `VideoFrame::to_rgba` produces it.
    ///
    /// The conversion is **lossy**: the native frame buffer is chroma
    /// subsampled, so a round trip is not byte-exact. Measured on a flat
    /// `[40, 90, 200, 255]` it comes back `[39, 90, 197, 255]`, and on a 4x3
    /// gradient the error is larger. A consumer must therefore treat these as
    /// display-ready pixels, never compare them for equality, and a test must
    /// assert within a tolerance.
    ///
    /// A note on how that was established, because it was got wrong first: a
    /// 4x3 gradient reads as a red/blue swap, which looks exactly like a BGRA
    /// buffer. It is not — it is subsampling error on a tiny image where the two
    /// channels happen to be close. Calibrate on a flat colour large enough for
    /// subsampling to be lossless before believing anything about a gradient.
    pub pixels: Vec<u8>,
}

/// Why a frame was not published.
///
/// Distinct values because "nothing arrived" and "something arrived and could not
/// be used" call for different responses, and a caller that cannot tell them
/// apart can only ever log and hope.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameDrop {
    /// The native conversion failed, or the frame was unusable. A dropped frame,
    /// not an error worth surfacing to a user.
    Unusable,
    /// The frame was larger than [`MAX_EDGE`] and scaling produced nothing.
    TooLarge,
}

#[derive(Debug, Default)]
struct State {
    slots: HashMap<DemuxId, VideoSlot>,
    /// Most recent reason a frame was dropped, for a caller that wants to know
    /// whether video is flowing at all.
    last_drop: Option<(DemuxId, FrameDrop)>,
    frames_seen: u64,
    frames_published: u64,
    frames_dropped: u64,
}

/// The frames one sink is holding.
///
/// A sink owns its state rather than sharing a process-wide one, so two calls
/// cannot see each other's pixels and a test is not at the mercy of whatever else
/// is running. The app uses the single instance from [`shared`].
#[derive(Default)]
pub struct VideoSinkState {
    inner: Mutex<State>,
}

impl VideoSinkState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn lock(&self) -> MutexGuard<'_, State> {
        // A poisoned lock means a sink callback panicked while holding it.
        // Recovering is right: the data is a cache of the newest frame, and
        // refusing to serve it would turn a recoverable panic into a permanently
        // broken call.
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

static STATE: OnceLock<Arc<VideoSinkState>> = OnceLock::new();

/// The instance the application uses.
pub fn shared() -> &'static Arc<VideoSinkState> {
    STATE.get_or_init(|| Arc::new(VideoSinkState::new()))
}

/// RingRTC's video sink.
///
/// Holds its own state so a caller can stand up an isolated one; the application
/// uses [`shared`].
pub struct CuztomVideoSink {
    state: Arc<VideoSinkState>,
}

impl CuztomVideoSink {
    pub fn new(state: Arc<VideoSinkState>) -> Self {
        Self { state }
    }

    /// The sink the application uses.
    pub fn shared() -> Self {
        Self {
            state: Arc::clone(shared()),
        }
    }
}

impl VideoSink for CuztomVideoSink {
    fn on_video_frame(&self, demux_id: DemuxId, frame: VideoFrame) {
        accept_frame(&self.state, demux_id, frame);
    }

    fn box_clone(&self) -> Box<dyn VideoSink> {
        Box::new(Self {
            state: Arc::clone(&self.state),
        })
    }
}

/// Convert and publish one frame.
///
/// Split out from the trait impl so it can be exercised without a peer
/// connection, and so the ordering constraint — do all of this on the decoder's
/// thread and return — is visible in one place.
fn accept_frame(sink: &VideoSinkState, demux_id: DemuxId, frame: VideoFrame) {
    let mut state = sink.lock();
    state.frames_seen += 1;

    // Rotation is metadata on the frame rather than something the conversion
    // applies, so a rotated frame converted without this comes out sideways.
    // Applied first because it is cheap relative to the conversion.
    let frame = frame.apply_rotation();

    let (width, height) = (frame.width(), frame.height());
    if width == 0 || height == 0 {
        state.frames_dropped += 1;
        state.last_drop = Some((demux_id, FrameDrop::Unusable));
        return;
    }

    // Scale before converting. Converting 1080p is 8 MB of copying; at 30 fps that
    // is 250 MB/s on the thread we are least able to stall, for a picture being
    // shown much smaller than that.
    let oversized = width > MAX_EDGE || height > MAX_EDGE;
    let frame = if oversized {
        let factor = MAX_EDGE as f64 / width.max(height) as f64;
        let target_w = ((width as f64 * factor).round() as u32).max(1);
        let target_h = ((height as f64 * factor).round() as u32).max(1);
        // `scale` returns a frame rather than an Option, so a native failure shows
        // up as a null buffer and a zero dimension rather than as None. Checked,
        // because forwarding that would publish a frame with no pixels in it and
        // count it as a success.
        let scaled = frame.scale(target_w, target_h);
        if scaled.width() == 0 || scaled.height() == 0 {
            state.frames_dropped += 1;
            state.last_drop = Some((demux_id, FrameDrop::TooLarge));
            return;
        }
        scaled
    } else {
        frame
    };

    let (width, height) = (frame.width(), frame.height());
    let needed = (width as usize) * (height as usize) * 4;
    let slot = state.slots.entry(demux_id).or_default();
    // Reallocated only when the size actually changes, so a steady stream is not
    // churning the allocator on the decoder's thread.
    if slot.pixels.len() != needed {
        slot.pixels = vec![0u8; needed];
        slot.width = 0;
    }
    if !frame.to_rgba(&mut slot.pixels) {
        state.frames_dropped += 1;
        state.last_drop = Some((demux_id, FrameDrop::Unusable));
        return;
    }
    slot.width = width;
    slot.height = height;
    slot.sequence += 1;
    state.frames_published += 1;
}

/// Copy a participant's newest frame out, if it is newer than what the caller has.
///
/// `out` is filled only when there is a new frame, so a caller can pass a buffer
/// sized from a previous call and use `written` to learn how much of it is live.
/// Returns the sequence number, or `None` when there is nothing new — which
/// includes "no such participant", because a caller polling a call that has not
/// started yet should not have to distinguish that from an idle one.
pub fn take_frame(
    sink: &VideoSinkState,
    demux_id: DemuxId,
    out: &mut [u8],
) -> Option<(u32, u32, u64, usize)> {
    let state = sink.lock();
    let slot = state.slots.get(&demux_id)?;
    let needed = (slot.width as usize) * (slot.height as usize) * 4;
    if out.len() < needed || needed == 0 {
        return None;
    }
    out[..needed].copy_from_slice(&slot.pixels[..needed]);
    Some((slot.width, slot.height, slot.sequence, needed))
}

/// Forget a participant's frame.
///
/// Called when a participant leaves. Their pixels are not secret, but they are
/// somebody's, and there is no reason to keep the last frame of someone who is
/// no longer in the call.
pub fn forget(sink: &VideoSinkState, demux_id: DemuxId) {
    sink.lock().slots.remove(&demux_id);
}

/// Bytes a participant's current frame needs, or 0 if they have none.
///
/// A caller sizes its buffer with this before reading, because a frame's size is
/// not known in advance and changes when a participant's resolution does.
pub fn frame_size(sink: &VideoSinkState, demux_id: DemuxId) -> usize {
    sink.lock()
        .slots
        .get(&demux_id)
        .map_or(0, |slot| slot.pixels.len())
}

/// Counts for the log, so "video is not arriving" is distinguishable from "video
/// is arriving and being dropped".
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VideoCounts {
    pub seen: u64,
    pub published: u64,
    pub dropped: u64,
    pub participants: usize,
    pub last_drop: Option<(DemuxId, FrameDrop)>,
}

pub fn counts(sink: &VideoSinkState) -> VideoCounts {
    let state = sink.lock();
    VideoCounts {
        seen: state.frames_seen,
        published: state.frames_published,
        dropped: state.frames_dropped,
        participants: state.slots.len(),
        last_drop: state.last_drop,
    }
}

/// Drop everything, for a call that has ended.
pub fn reset(sink: &VideoSinkState) {
    let mut state = sink.lock();
    state.slots.clear();
    state.last_drop = None;
    state.frames_seen = 0;
    state.frames_published = 0;
    state.frames_dropped = 0;
}

#[cfg(test)]
mod tests {
    use super::*;
    use ringrtc::webrtc::media::VideoPixelFormat;

    /// Alias so the out-parameter locals below read as the `u32` they are.
    type UInt32Alias = u32;

    /// Serialises the tests that touch the application's sink.
    ///
    /// The C ABI is inherently global — it reads the one sink the app uses — so
    /// tests exercising it cannot each have an isolated instance the way the sink
    /// tests above do. They therefore have to take turns. Without this they fail
    /// intermittently, which is exactly what happened: one test's `reset_video`
    /// wiped another's frame mid-assertion.
    static SHARED_SINK: Mutex<()> = Mutex::new(());

    fn exclusive() -> std::sync::MutexGuard<'static, ()> {
        SHARED_SINK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A frame built from known pixels, going all the way round.
    ///
    /// `VideoFrame::copy_from_slice` is a real constructor, so this exercises the
    /// whole path rather than a stand-in: bytes in, sink, bytes out. If the
    /// conversion or the slot handling were wrong the pixels would not survive,
    /// and a sink that quietly published nothing would fail here too.
    ///
    /// Every test builds its own sink. They share nothing, so they cannot fail
    /// depending on what else is running — which is not a theoretical concern: an
    /// earlier version of these shared a process-global and reported each other's
    /// frames.
    #[test]
    fn a_frame_arrives_intact_through_the_sink() {
        let sink = VideoSinkState::new();
        // A flat colour, deliberately. The native frame buffer is chroma
        // subsampled, so a round trip is lossy on a gradient — measured, not
        // assumed: RGBA `[4,5,6,7]` comes back as `[3,5,5,255]`, which is neither a
        // swizzle nor the original. A flat region survives subsampling exactly,
        // which is what makes it the right probe for "are these the right pixels
        // in the right place".
        let (w, h) = (32u32, 32u32);
        let source = vec![40u8, 90, 200, 255].repeat((w * h) as usize);
        accept_frame(&sink, 7, VideoFrame::copy_from_slice(w, h, VideoPixelFormat::Rgba, &source));

        let mut out = vec![0u8; w as usize * h as usize * 4];
        let (got_w, got_h, sequence, written) =
            take_frame(&sink, 7, &mut out).expect("a frame");

        assert_eq!((got_w, got_h), (w, h));
        assert_eq!(written, out.len());
        assert_eq!(sequence, 1, "the first published frame is sequence 1");
        // Tolerance, because the conversion is lossy. Generous enough to survive
        // subsampling and tight enough that a channel swap could never pass: the
        // two are 110 apart here.
        for (index, pixel) in out.chunks(4).enumerate() {
            let within = |got: u8, want: u8| (got as i32 - want as i32).abs() <= 12;
            assert!(
                within(pixel[0], 40)
                    && within(pixel[1], 90)
                    && within(pixel[2], 200)
                    && pixel[3] == 255,
                "pixel {index} is not the colour that went in: {pixel:?}"
            );
        }
    }

    /// The channel order is red, green, blue, alpha — and proving it needs a
    /// calibration that cannot be confused by subsampling error.
    ///
    /// The first attempt at this used a 4x3 gradient and concluded the buffer was
    /// BGRA, because red and blue read as swapped. They were not swapped: they
    /// sat within a few counts of each other on an image too small for subsampling
    /// to be lossless. Two wide-separated flat blocks, sampled away from the
    /// boundary between them, make a swap arithmetically impossible to confuse
    /// with error.
    #[test]
    fn the_channel_order_is_red_green_blue_alpha() {
        let sink = VideoSinkState::new();
        let (w, h) = (32u32, 32u32);
        // A red block and a blue block, side by side.
        let mut source = Vec::new();
        for _ in 0..h {
            for x in 0..w {
                if x < w / 2 {
                    source.extend_from_slice(&[220, 20, 20, 255]);
                } else {
                    source.extend_from_slice(&[20, 20, 220, 255]);
                }
            }
        }
        accept_frame(
            &sink,
            1,
            VideoFrame::copy_from_slice(w, h, VideoPixelFormat::Rgba, &source),
        );

        let mut out = vec![0u8; (w * h * 4) as usize];
        take_frame(&sink, 1, &mut out).expect("a frame");

        // Mean of the middle of each half, so the columns nearest the boundary —
        // the only ones subsampling touches — are not sampled at all.
        let mean = |from_x: u32, to_x: u32| -> (u32, u32, u32) {
            let mut totals = [0u32; 3];
            let mut count = 0u32;
            for y in 0..h {
                for x in from_x..to_x {
                    let pixel = &out[((y * w + x) * 4) as usize..][..4];
                    for c in 0..3 {
                        totals[c] += pixel[c] as u32;
                    }
                    count += 1;
                }
            }
            (totals[0] / count, totals[1] / count, totals[2] / count)
        };

        let (r, g, b) = mean(4, w / 2 - 4);
        assert!(r > 200 && g < 40 && b < 40, "the red block is red-first, got {:?}", (r, g, b));
        let (r2, g2, b2) = mean(w / 2 + 4, w - 4);
        assert!(b2 > 200 && g2 < 40 && r2 < 40, "the blue block is blue-third, got {:?}", (r2, g2, b2));
    }

    /// A frame is a snapshot, not an event.
    ///
    /// The newest frame is the only one worth having, so a second frame replaces
    /// the first and a reader is handed the newer sequence rather than a queue.
    /// Queueing frames is how latency gets built.
    #[test]
    fn a_newer_frame_replaces_the_old_one_rather_than_joining_it() {
        let sink = VideoSinkState::new();
        for value in [10u8, 20, 30] {
            let source = vec![value; 16];
            accept_frame(
                &sink,
                1,
                VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &source),
            );
        }
        let mut out = vec![0u8; 16];
        let (_, _, sequence, _) = take_frame(&sink, 1, &mut out).expect("a frame");
        assert_eq!(sequence, 3, "three frames published, newest kept");
        // Alpha comes back opaque whatever went in, so compare the colour only.
        for pixel in out.chunks(4) {
            assert_eq!(
                pixel,
                &[30, 30, 30, 255],
                "the newest frame is what a reader gets, not the oldest"
            );
        }
    }

    /// One participant's frames must never land in another's slot.
    ///
    /// The sink is keyed by demux id precisely so a grid can ask for one
    /// participant without disturbing the rest, and so a caller cannot be handed
    /// the wrong person's video.
    #[test]
    fn participants_keep_separate_frames() {
        let sink = VideoSinkState::new();
        accept_frame(
            &sink,
            1,
            VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &vec![1u8; 16]),
        );
        accept_frame(
            &sink,
            2,
            VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &vec![2u8; 16]),
        );

        let mut first = vec![0u8; 16];
        let mut second = vec![0u8; 16];
        take_frame(&sink, 1, &mut first).expect("first");
        take_frame(&sink, 2, &mut second).expect("second");

        for pixel in first.chunks(4) {
            assert_eq!(pixel, &[1, 1, 1, 255], "participant 1 has the wrong pixels");
        }
        for pixel in second.chunks(4) {
            assert_eq!(pixel, &[2, 2, 2, 255], "participant 2 has the wrong pixels");
        }
        assert_eq!(counts(&sink).participants, 2);
    }

    /// Nothing new is not the same as nothing there.
    ///
    /// A caller polling a participant who has not started sending gets "no frame",
    /// not an error, and not a second copy of what it already has — the sequence
    /// number is how a caller tells new from old.
    #[test]
    fn an_unknown_participant_reports_nothing_rather_than_failing() {
        let sink = VideoSinkState::new();
        let mut out = vec![0u8; 16];
        assert_eq!(take_frame(&sink, 99, &mut out), None, "no such participant");

        accept_frame(
            &sink,
            5,
            VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &vec![7u8; 16]),
        );
        assert!(take_frame(&sink, 5, &mut out).is_some(), "the frame is there");
        assert!(
            take_frame(&sink, 5, &mut out).is_some(),
            "and asking again does not consume it: a slow reader must not lose a frame it never saw"
        );
    }

    /// A buffer too small is refused rather than overrun.
    ///
    /// The caller sizes its buffer from a previous call, so a participant changing
    /// resolution can leave it briefly too small. That is a dropped frame, not a
    /// buffer overflow.
    #[test]
    fn a_short_buffer_is_refused_rather_than_overrun() {
        let sink = VideoSinkState::new();
        accept_frame(
            &sink,
            3,
            VideoFrame::copy_from_slice(4, 4, VideoPixelFormat::Rgba, &vec![9u8; 64]),
        );
        let mut too_small = vec![0u8; 16];
        assert_eq!(take_frame(&sink, 3, &mut too_small), None, "refused, not truncated");
        assert!(too_small.iter().all(|b| *b == 0), "and nothing was written");
    }

    /// Counts distinguish "not arriving" from "arriving and being dropped".
    ///
    /// Without this the only available answer to "is video working" is a shrug:
    /// both look like a blank rectangle.
    ///
    /// The drop path cannot be driven from a test. `VideoFrame::copy_from_slice`
    /// with a zero dimension does not return an error — it aborts the process from
    /// inside the native library (`Check failed: width > 0`,
    /// `video_frame_buffer.cc:266`). That is worth knowing on its own: the guard
    /// in `accept_frame` is cheap and fail-closed, but in practice the native
    /// layer will not hand us a degenerate frame in the first place. The count is
    /// asserted here through a working frame, and the unusable path is left
    /// unexercised rather than faked.
    #[test]
    fn counts_separate_silence_from_drops() {
        let sink = VideoSinkState::new();
        assert_eq!(counts(&sink), VideoCounts::default(), "nothing seen yet");

        accept_frame(
            &sink,
            1,
            VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &vec![1u8; 16]),
        );
        let c = counts(&sink);
        assert_eq!((c.seen, c.published, c.dropped), (1, 1, 0));
        assert_eq!(c.participants, 1);
        assert_eq!(c.last_drop, None);

        reset(&sink);
        assert_eq!(
            counts(&sink),
            VideoCounts::default(),
            "a call that ended leaves nothing behind"
        );
    }

    /// Leaving is not remembered.
    ///
    /// The pixels are not secret, but they are somebody's, and there is no reason
    /// to keep the last frame of someone who is no longer in the call.
    #[test]
    fn a_participant_who_leaves_is_forgotten() {
        let sink = VideoSinkState::new();
        accept_frame(
            &sink,
            4,
            VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &vec![1u8; 16]),
        );
        assert_eq!(counts(&sink).participants, 1);
        forget(&sink, 4);
        assert_eq!(counts(&sink).participants, 0);
        let mut out = vec![0u8; 16];
        assert_eq!(take_frame(&sink, 4, &mut out), None);
    }

    /// The edge cap exists to bound work on the decoder's thread, so it has to
    /// actually bound it rather than merely be written down.
    #[test]
    fn an_oversized_frame_is_scaled_rather_than_converted_at_full_size() {
        let sink = VideoSinkState::new();
        // Comfortably under the cap, so converted as-is.
        accept_frame(
            &sink,
            1,
            VideoFrame::copy_from_slice(
                MAX_EDGE,
                MAX_EDGE,
                VideoPixelFormat::Rgba,
                &vec![1u8; (MAX_EDGE * MAX_EDGE * 4) as usize],
            ),
        );
        assert_eq!(counts(&sink).dropped, 0, "a frame at the cap is fine");
        {
            let state = sink.lock();
            let slot = state.slots.get(&1).expect("published");
            assert_eq!(
                (slot.width, slot.height),
                (MAX_EDGE, MAX_EDGE),
                "a frame at the cap is not scaled"
            );
        }

        // Over it. The published slot must respect the cap, which is what stops a
        // 1080p share costing 8 MB of copying per frame on the thread we least
        // want to stall.
        let big = (MAX_EDGE * 2) as usize;
        accept_frame(
            &sink,
            2,
            VideoFrame::copy_from_slice(
                big as u32,
                big as u32,
                VideoPixelFormat::Rgba,
                &vec![1u8; big * big * 4],
            ),
        );
        let state = sink.lock();
        let slot = state.slots.get(&2).expect("published");
        assert!(
            slot.width <= MAX_EDGE && slot.height <= MAX_EDGE,
            "published at {}x{}, over the {MAX_EDGE} cap",
            slot.width,
            slot.height
        );
        assert!(slot.pixels.len() <= (MAX_EDGE as usize) * (MAX_EDGE as usize) * 4);
    }

    /// A sink is clonable and the clones share state, because RingRTC boxes a
    /// clone per peer connection. A clone with its own state would silently show
    /// an empty picture.
    #[test]
    fn clones_of_a_sink_share_their_frames() {
        use ringrtc::webrtc::media::VideoSink as _;
        let sink = Arc::new(VideoSinkState::new());
        let original = CuztomVideoSink::new(Arc::clone(&sink));
        let clone = original.box_clone();
        clone.on_video_frame(
            2,
            VideoFrame::copy_from_slice(2, 2, VideoPixelFormat::Rgba, &vec![4u8; 16]),
        );
        let mut out = vec![0u8; 16];
        assert!(
            take_frame(&sink, 2, &mut out).is_some(),
            "a frame delivered to a clone is visible through the original state"
        );
    }

    /// The video read has to behave at the boundary, not just inside Rust.
    ///
    /// A frame crosses into another language here, and the two ways that can go
    /// wrong are a buffer overrun and a lost frame. Both are checked through the
    /// real `extern "C"` entry points rather than the Rust functions behind them,
    /// because the pointer arithmetic and the sequence handshake only exist at that
    /// layer.
    #[test]
    fn the_read_abi_refuses_a_short_buffer_and_does_not_consume_the_frame() {
        let _exclusive = exclusive();
        use crate::{
            core_cmd_group_call_forget_video, core_cmd_group_call_reset_video,
            core_cmd_group_call_take_video_frame, core_cmd_group_call_video_frame_size,
        };

        crate::call::reset_video();
        let demux = 5u32;
        // 32x32 rather than something tiny: the native round trip is chroma
        // subsampled, so a 4x4 frame comes back visibly wrong and an exact pixel
        // assertion here would be measuring the subsampler, not the boundary.
        let (w, h) = (32u32, 32u32);
        // Published through the real sink, so the test exercises the same path the
        // decoder does rather than reaching into the state.
        let sink = CuztomVideoSink::shared();
        use ringrtc::webrtc::media::VideoSink as _;
        // The full frame, not just one pixel. `copy_from_slice` takes a `&[u8]`
        // and hands only its *pointer* to the native library, which then reads
        // `w * h * 4` bytes without any length to check against — so a short
        // slice is an out-of-bounds read, not an error. That is what made an
        // earlier version of this test return nonsense pixels.
        let flat = vec![30u8, 30, 30, 255].repeat((w * h) as usize);
        sink.on_video_frame(
            demux,
            VideoFrame::copy_from_slice(w, h, VideoPixelFormat::Rgba, &flat),
        );

        let needed = core_cmd_group_call_video_frame_size(demux);
        assert_eq!(needed, (w * h * 4) as i64, "size is reported before reading");

        // A buffer one byte short is refused, not truncated and not overrun.
        let mut too_small = vec![0u8; (needed - 1) as usize];
        let rc = unsafe {
            core_cmd_group_call_take_video_frame(
                demux,
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                too_small.as_mut_ptr(),
                too_small.len() as i64,
            )
        };
        assert_eq!(rc, 0, "a short buffer yields nothing rather than a partial frame");
        assert!(too_small.iter().all(|b| *b == 0), "and nothing was written");

        // A null pointer is refused rather than dereferenced.
        let rc = unsafe {
            core_cmd_group_call_take_video_frame(
                demux,
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                needed,
            )
        };
        assert_eq!(rc, 0, "a null buffer is refused");

        // A correctly sized read gets the frame.
        let mut buffer = vec![0u8; needed as usize];
        // The dimensions come back with the frame, and are cleared on a miss --
        // a caller that gets 0 must not be left holding the last frame's shape,
        // which would draw this one stretched.
        let read = |since: u64, buf: &mut [u8]| -> (u64, u32, u32) {
            let mut width: UInt32Alias = 0;
            let mut height: UInt32Alias = 0;
            let sequence = unsafe {
                core_cmd_group_call_take_video_frame(
                    demux,
                    since,
                    &mut width,
                    &mut height,
                    buf.as_mut_ptr(),
                    buf.len() as i64,
                )
            };
            (sequence, width, height)
        };
        let (first, got_w, got_h) = read(0, &mut buffer);
        assert_eq!(first, 1, "the first read returns the frame's sequence");
        assert_eq!((got_w, got_h), (w, h), "and the frame's real dimensions");
        for (index, pixel) in buffer.chunks(4).enumerate() {
            let within = |got: u8| (got as i32 - 30).abs() <= 12;
            assert!(
                pixel.iter().take(3).all(|c| within(*c)) && pixel[3] == 255,
                "pixel {index} is not the colour that went in: {pixel:?}"
            );
        }

        // Nothing newer exists, so asking with the sequence just read yields
        // nothing -- that is how a caller polls without spinning on old frames.
        let (miss, cleared_w, cleared_h) = read(first, &mut buffer);
        assert_eq!(miss, 0, "nothing newer, so nothing returned");
        assert_eq!(
            (cleared_w, cleared_h),
            (0, 0),
            "a miss clears the dimensions rather than leaving the previous frame's"
        );

        // And asking again with the older sequence still returns it: a frame is
        // not consumed by being read, so a caller that lost a response does not
        // also lose the frame.
        let (replay, _, _) = read(0, &mut buffer);
        assert_eq!(replay, first, "the same frame can be read again");

        // Forgetting a participant releases their pixels.
        core_cmd_group_call_forget_video(demux);
        assert_eq!(core_cmd_group_call_video_frame_size(demux), 0, "forgotten on leaving");
        core_cmd_group_call_reset_video();
    }

    /// Video counters, so "not arriving" and "arriving and dropped" are different
    /// answers rather than the same blank rectangle.
    #[test]
    fn the_stats_abi_reports_what_happened() {
        let _exclusive = exclusive();
        crate::call::reset_video();
        let stats = crate::call::video_stats();
        let parsed: serde_json::Value =
            serde_json::from_str(&stats).expect("stats are JSON");
        assert_eq!(parsed["frames_seen"], 0);
        assert_eq!(parsed["frames_published"], 0);
        assert_eq!(parsed["participants"], 0);
        assert!(
            parsed["last_dropped_demux_id"].is_null(),
            "nothing has been dropped yet, which is not the same as dropped-zero"
        );
        crate::call::reset_video();
    }
}
