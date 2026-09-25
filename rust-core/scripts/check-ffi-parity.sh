#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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

rust_abi=$(sed -nE 's/.*CORE_ABI_VERSION: u32 = ([0-9]+).*/\1/p' "$source" | head -n 1)
header_abi=$(sed -nE 's/.*CUZTOM_SIGNAL_CORE_ABI_VERSION[[:space:]]+([0-9]+)u.*/\1/p' "$header" | head -n 1)
if [ -z "$rust_abi" ] || [ "$rust_abi" != "$header_abi" ]; then
  echo "C header ABI does not match Rust (Rust=$rust_abi header=$header_abi)" >&2
  missing=1
fi

[ "$missing" -eq 0 ]
