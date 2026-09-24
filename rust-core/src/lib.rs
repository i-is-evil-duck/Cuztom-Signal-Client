//! Cuztom Signal Rust core — M1 target.
//!
//! Plan: wrap `presage::Manager` (which itself uses libsignal under the
//! hood) and expose a small C ABI for Swift:
//! `link_device_qr`, `link_poll`, `sync_now`, `send_text`, `poll_incoming`.
//! M0 ships this file as a documented stub; real presage wiring lands in M1
//! once `cargo` is installed (`rustup` / `brew install rustup`).

/// Opaque handle returned to Swift. M1 backs this with a presage Manager.
#[repr(C)]
pub struct CoreHandle {
    _private: [u8; 0],
}

/// Start linked-device provisioning. Returns a QR payload string the Swift
/// UI renders. Mirrors `presage-cli link-device --device-name <name>`.
#[no_mangle]
pub extern "C" fn link_device_qr(_device_name: *const core::ffi::c_char) -> *mut core::ffi::c_char {
    // M1: call presage Manager::link_secondary_device and return real URI.
    core::ptr::null_mut()
}

/// Free a string returned by this library.
#[no_mangle]
pub extern "C" fn core_free_string(_s: *mut core::ffi::c_char) {}

/* M1 checklist (in order):
 * 1. `cargo add presage presage-store-sqlite tokio serde serde_json`
 * 2. Implement Manager singleton + SqliteStore at
 *    ~/Library/Application Support/CuztomSignal/signal.db (SQLCipher later).
 * 3. link-device -> QR URI -> wait for phone confirmation.
 * 4. contacts/groups sync -> push rows into Swift MessageStore via callback.
 * 5. send/receive text -> attachment CDN fetch in M2.
 * 6. Generate XCFramework: `rust-core/build-xcframework.sh` (cbindgen+uniffi).
 */
