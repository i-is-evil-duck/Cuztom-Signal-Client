#!/bin/sh
# Check that the Rust externs, the C header, and the Swift loader all agree.
#
# Three-way, and the third direction exists because of a bug this script could not
# see. `core_cmd_group_call_set_video_muted` lost its `#[no_mangle]` to an editing
# mistake. The symbol was not exported, the Swift loader's `resolve` returned nil
# for a single missing symbol, and the app refused to start with
# "rust core not found" — a message that points at the bundle, not at one missing
# attribute.
#
# The original check only asked "is every `#[no_mangle]` function in the header?".
# A function that loses the attribute simply stops being in that list, so the
# check had nothing to complain about. Hence the reverse direction below, and
# hence the loader check, which is the one that would actually have caught it.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
header="$root/include/cuztom_signal_core.h"
source="$root/src/lib.rs"

names=$(sed -n '/#\[no_mangle\]/{n;s/.*fn \(core_[A-Za-z0-9_]*\).*/\1/p;}' "$source" | sort -u)
missing=0

for name in $names; do
  if ! grep -Eq "${name}[[:space:]]*\(" "$header"; then
    echo "missing C header declaration: $name" >&2
    missing=1
  fi
done

# The reverse direction: every `core_` function in the header must be a
# `#[no_mangle]` Rust extern. Without this, deleting or misplacing one attribute
# removes a symbol from the library while every existing check still passes.
declared=$(sed -nE 's/^[a-z0-9_ *]*\**(core_[A-Za-z0-9_]+)\(.*/\1/p' "$header" | sort -u)
for name in $declared; do
  if ! printf '%s\n' "$names" | grep -qx "$name"; then
    echo "header declares $name but no #[no_mangle] Rust extern provides it" >&2
    missing=1
  fi
done

# And the Swift loader must only ask for symbols the header declares, so a typo in
# a `dlsym` string is caught here rather than as a nil function pointer at runtime.
loader="$root/../Sources/CuztomSignalCore/RustCoreService.swift"
if [ -f "$loader" ]; then
  asked=$(sed -n 's/.*dlsym(handle, "\(core_[A-Za-z0-9_]*\)").*/\1/p' "$loader" | sort -u)
  for name in $asked; do
    if ! printf '%s\n' "$declared" | grep -qx "$name"; then
      echo "the Swift loader asks for $name, which the header does not declare" >&2
      missing=1
    fi
  done
  # A symbol the loader never asks for is a command nothing can reach. Group
  # management commands are knowingly in that state and are listed in the Swift
  # test that asserts it, so they are reported rather than failed here.
  unreachable=$(printf '%s\n' "$declared" | grep -vxF "$asked" || true)
  if [ -n "$unreachable" ]; then
    echo "note: declared but not reachable from Swift:" >&2
    printf '  %s\n' $unreachable >&2
  fi
fi

rust_abi=$(sed -nE 's/.*CORE_ABI_VERSION: u32 = ([0-9]+).*/\1/p' "$source" | head -n 1)
header_abi=$(sed -nE 's/.*CUZTOM_SIGNAL_CORE_ABI_VERSION[[:space:]]+([0-9]+)u.*/\1/p' "$header" | head -n 1)
if [ -z "$rust_abi" ] || [ "$rust_abi" != "$header_abi" ]; then
  echo "C header ABI does not match Rust (Rust=$rust_abi header=$header_abi)" >&2
  missing=1
fi

[ "$missing" -eq 0 ]
