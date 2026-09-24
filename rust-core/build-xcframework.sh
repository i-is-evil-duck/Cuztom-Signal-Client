#!/bin/sh
# M1 helper: build Rust core for arm64 + x86_64 macOS and lipo into an XCFramework.
# Requires: rustup with targets aarch64-apple-darwin + x86_64-apple-darwin, cbindgen.
set -eu
cd "$(dirname "$0")"
cargo build --release
echo "M1 TODO: cbindgen headers + xcodebuild -create-xcframework"
echo "Built: target/release/libcuztom_signal_core.a"
