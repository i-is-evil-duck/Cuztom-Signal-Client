#!/bin/sh
# Preflight a CuztomSignal.app bundle against the same rules the release
# loader applies, so a broken bundle fails here instead of showing
# "rust core not found" in the UI.
#
# Mirrors RustCoreService.preflightLibrary/validateLoadedLibrary:
#   * dylib lives inside the bundle
#   * dylib carries a valid (strict, nested) code signature
#   * dylib matches CuztomSignalCoreSHA256 from Info.plist, when present
#   * the dylib reports the expected ABI version
#
# Usage: scripts/verify-app.sh [path/to/CuztomSignal.app]
set -eu

bundle=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/build/CuztomSignal.app"}
dylib="$bundle/Contents/MacOS/libcuztom_signal_core.dylib"
exe="$bundle/Contents/MacOS/CuztomSignal"
framework="$bundle/Contents/Frameworks/SQLCipher.framework"
# Read the expected ABI from the header rather than hardcoding it. A stale
# literal here silently passes or fails for the wrong reason every time the ABI
# moves, and the check is only worth having if it tracks the real contract.
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header="$repo_root/rust-core/include/cuztom_signal_core.h"
expected_abi=$(sed -n 's/^#define CUZTOM_SIGNAL_CORE_ABI_VERSION \([0-9]*\)u$/\1/p' "$header")
[ -n "$expected_abi" ] || {
    echo "could not read CUZTOM_SIGNAL_CORE_ABI_VERSION from $header" >&2
    exit 1
}
fail=0

note() { printf '    %s\n' "$1"; }
bad() { printf '    FAIL: %s\n' "$1" >&2; fail=1; }

[ -d "$bundle" ] || { echo "no bundle at $bundle" >&2; exit 1; }

for required in "$exe" "$dylib" "$framework"; do
    [ -e "$required" ] || bad "missing $required"
done

bundle_root=$(cd "$bundle" && pwd -P)
dylib_root=$(cd "$(dirname "$dylib")" && pwd -P)
case "$dylib_root" in
    "$bundle_root"/*) note "dylib is inside the bundle" ;;
    *) bad "dylib is outside the bundle (release builds reject this)" ;;
esac

if codesign --verify --strict "$dylib" >/dev/null 2>&1; then
    note "dylib signature valid"
else
    bad "dylib signature is not valid"
fi

expected_hash=$(/usr/libexec/PlistBuddy -c "Print :CuztomSignalCoreSHA256" \
    "$bundle/Contents/Info.plist" 2>/dev/null || true)
if [ -n "$expected_hash" ]; then
    actual_hash=$(shasum -a 256 "$dylib" | awk '{print $1}')
    if [ "$expected_hash" = "$actual_hash" ]; then
        note "dylib sha256 matches Info.plist"
    else
        bad "dylib sha256 mismatch (plist=$expected_hash file=$actual_hash)"
    fi
else
    note "no CuztomSignalCoreSHA256 in Info.plist; the app will skip the hash check"
fi

# Ask the dylib itself for its ABI version rather than trusting the file name.
abi_probe=$(mktemp -t cuztom_abi).c
abi_bin=${abi_probe%.c}
cat > "$abi_probe" <<C
#include <stdint.h>
#include <stdio.h>
#include <dlfcn.h>
int main(void) {
    void *handle = dlopen("$dylib", RTLD_NOW);
    if (!handle) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 127; }
    uint32_t (*abi)(void) = (uint32_t (*)(void))dlsym(handle, "core_abi_version");
    if (!abi) { fprintf(stderr, "core_abi_version missing\n"); return 126; }
    return (int)abi();
}
C
abi=unknown
if cc -x c -o "$abi_bin" "$abi_probe" >/dev/null 2>&1; then
    abi=$("$abi_bin" 2>/dev/null) || abi=$?
fi
rm -f "$abi_probe" "$abi_bin"
if [ "$abi" = "$expected_abi" ]; then
    note "native ABI version $abi"
else
    bad "native ABI mismatch (expected $expected_abi, got $abi)"
fi

if codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
    note "app bundle signature valid"
else
    bad "app bundle signature is not valid"
fi

[ "$fail" -eq 0 ] || exit 1
echo "    bundle OK"
