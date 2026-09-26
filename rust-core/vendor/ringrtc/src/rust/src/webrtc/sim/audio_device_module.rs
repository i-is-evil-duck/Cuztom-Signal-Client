//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

use std::ffi::c_void;

use libc::size_t;

#[allow(non_snake_case, clippy::missing_safety_doc)]
pub unsafe fn Rust_recordedDataIsAvailable(
    _audio_callback_ptr: usize,
    _audio_samples: *const c_void,
    _n_samples: size_t,
    _n_bytes_per_sample: size_t,
    _n_channels: size_t,
    _samples_per_sec: u32,
    _total_delay_ms: u32,
    _clock_drift: i32,
    _current_mic_level: u32,
    _key_pressed: bool,
    _new_mic_level: *mut u32,
    _estimated_capture_time_ns: i64,
) -> i32 {
    -1
}

#[allow(non_snake_case, clippy::missing_safety_doc)]
pub unsafe fn Rust_needMorePlayData(
    _audio_callback_ptr: usize,
    _n_samples: size_t,
    _n_bytes_per_sample: size_t,
    _n_channels: size_t,
    _samples_per_sec: u32,
    _audio_samples: *mut c_void,
    _n_samples_out: *mut size_t,
    _elapsed_time_ms: *mut i64,
    _ntp_time_ms: *mut i64,
) -> i32 {
    -1
}
