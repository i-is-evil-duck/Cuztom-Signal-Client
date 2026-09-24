# rust-core — Rust service core (presage + libsignal)

## Prerequisites (macOS arm64, verified 2026-09-24)

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
# protoc — required by `spqr` (Signal PQ ratchet) build script via presage -> libsignal
brew install protobuf
```

Verified: rustc/cargo 1.98.1, `cargo fetch` + `cargo check` green.

## Commands

```bash
cargo fetch   # resolve + download deps (presage from git)
cargo check   # typecheck incl. presage + presage-store-sqlite
cargo build --release  # produces target/release/libcuztom_signal_core.{a,dylib}
./build-xcframework.sh # M1: headers + XCFramework for Swift (cbindgen/uniffi)
```

## FFI surface (see `src/lib.rs`)

- `link_device_qr(device_name) -> *mut c_char` — presage link-device QR URI (M1)
- `core_free_string(s)` — free strings returned to Swift

Swift loads the built dylib via `RustCoreService` (dlopen, optional) — the app
builds and tests without Rust; linking/real sync needs this crate built.
