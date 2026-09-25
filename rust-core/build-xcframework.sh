#!/bin/sh
# Build the Rust core for macOS (arm64 + x86_64) and lipo into an XCFramework.
#
# Notes
# -----
# * `ringrtc` is built with `native` + `prebuilt_webrtc`. That pulls Signal's
#   prebuilt libwebrtc for the host (macOS arm64/x86_64) and links the macOS
#   audio frameworks (CoreAudio / AudioToolbox / AudioUnit) for calls.
# * The prebuilt is fetched by ringrtc's `webrtc-sys` build script, which calls
#   `bin/env.sh`. That script probes for GNU `realpath -e`; macOS's realpath
#   lacks `-e`, so it falls back to `grealpath` from Homebrew coreutils.
#   `scripts/grealpath` is a dependency-free shim, so no `brew install
#   coreutils` is required. We put it on PATH for the build.
set -eu
cd "$(dirname "$0")"

PATH="$PWD/scripts:$PATH"
export PATH

# arm64 (Apple silicon) — the common case.
cargo build --release

# x86_64 (Intel) is built on demand; uncomment if you need a universal binary.
# rustup target add x86_64-apple-darwin
# cargo build --release --target x86_64-apple-darwin

echo "Built: target/release/libcuztom_signal_core.dylib"
echo "M1 TODO: cbindgen headers + xcodebuild -create-xcframework"
