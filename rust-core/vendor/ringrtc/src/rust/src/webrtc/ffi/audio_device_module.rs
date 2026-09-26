//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

//! WebRTC FFI ADM interface.

use std::ffi::c_void;

use libc::size_t;

unsafe extern "C" {
    pub fn Rust_recordedDataIsAvailable(
        audio_callback_ptr_ptr: usize,
        audio_samples: *const c_void,
        n_samples: size_t,
        n_bytes_per_sample: size_t,
        n_channels: size_t,
        samples_per_sec: u32,
        total_delay_ms: u32,
        clock_drift: i32,
        current_mic_level: u32,
        key_pressed: bool,
        new_mic_level: *mut u32,
        estimated_capture_time_ns: i64,
    ) -> i32;

    pub fn Rust_needMorePlayData(
        audio_callback_ptr_ptr: usize,
        n_samples: size_t,
        n_bytes_per_sample: size_t,
        n_channels: size_t,
        samples_per_sec: u32,
        audio_samples: *mut c_void,
        n_samples_out: *mut size_t,
        elapsed_time_ms: *mut i64,
        ntp_time_ms: *mut i64,
    ) -> i32;
}
