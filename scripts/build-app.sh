#!/bin/sh
# Build a locally runnable, ad-hoc signed CuztomSignal.app bundle.
#
# Release builds enforce dylib trust (see RustCoreService.validateLoadedLibrary):
# the native core must live inside the bundle, carry a valid code signature, and
# match CuztomSignalCoreSHA256 in Info.plist. This script therefore signs the
# dylib first, hashes the signed result, writes the Info.plist, and signs the
# bundle last.
#
# This is a development bundle, not a consumer release: it is ad-hoc signed and
# not notarized. See IMPLEMENTATION_PLAN.md (Milestone 7).
#
# Usage: scripts/build-app.sh [version] [build]   (defaults: 0.1.0 / 1)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=${1:-0.1.0}
build=${2:-1}
bundle="$root/build/CuztomSignal.app"
bundle_id="com.cuztomsignal.mac"
dylib_name="libcuztom_signal_core.dylib"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

echo "==> Building native core (rust-core, release)"
(cd rust-core && PATH="$PWD/scripts:$PATH" cargo build --release)

echo "==> Building Swift app (release)"
# @executable_path/../Frameworks is required so the embedded SQLCipher framework
# resolves from a real bundle layout.
swift build -c release --product CuztomSignal \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "==> Assembling $bundle"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources"

cp .build/release/CuztomSignal "$bundle/Contents/MacOS/CuztomSignal"
cp "rust-core/target/release/$dylib_name" "$bundle/Contents/MacOS/$dylib_name"
cp -R .build/release/SQLCipher.framework "$bundle/Contents/Frameworks/SQLCipher.framework"
cp -R .build/release/GRDB_GRDB.bundle "$bundle/Contents/Resources/GRDB_GRDB.bundle"

chmod +x "$bundle/Contents/MacOS/CuztomSignal"

echo "==> Signing (ad-hoc) and hashing the native core"
# The dylib must be signed before it is hashed: a later re-sign would change
# the bytes that CuztomSignalCoreSHA256 records.
codesign --force --sign - "$bundle/Contents/MacOS/CuztomSignal"
codesign --force --sign - "$bundle/Contents/MacOS/$dylib_name"
codesign --force --sign - "$bundle/Contents/Frameworks/SQLCipher.framework"

dylib_sha=$(shasum -a 256 "$bundle/Contents/MacOS/$dylib_name" | awk '{print $1}')

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CuztomSignal</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CuztomSignal</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Cuztom Signal needs microphone access to place and answer voice calls.</string>
    <key>CuztomSignalCoreSHA256</key>
    <string>$dylib_sha</string>
</dict>
</plist>
PLIST

echo "==> Signing app bundle"
codesign --force --sign - --timestamp=none "$bundle"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$bundle" 2>&1 | sed 's/^/    /'
"$root/scripts/verify-app.sh" "$bundle"
echo "==> Built $bundle (version $version build $build)"
echo "    Run with: open \"$bundle\""
