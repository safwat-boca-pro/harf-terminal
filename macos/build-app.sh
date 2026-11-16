#!/bin/sh
# Builds libharf.a (Zig), the Swift shell, and assembles macos/.build/Harf.app.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# A SDKROOT exported by the user's shell can point at an SDK newer than the
# selected Swift toolchain ("this SDK is not supported by the compiler").
# Let xcrun pick the SDK that matches the toolchain.
unset SDKROOT
# Prefer the project-local Zig (.tools/zig) when present; CI uses the brew one.
[ -x "$ROOT/.tools/zig/zig" ] && PATH="$ROOT/.tools/zig:$PATH"

(cd "$ROOT" && zig build -Doptimize=ReleaseFast)
# SwiftPM does not notice that libharf.a changed, so a Zig-only change would leave the old binary in place.
# Remove the linked product to force a relink against the fresh library.
rm -f "$ROOT/macos/.build/release/Harf"
(cd "$ROOT/macos" && swift build -c release -Xlinker -L"$ROOT/zig-out/lib")

APP="$ROOT/macos/.build/Harf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/macos/.build/release/Harf" "$APP/Contents/MacOS/Harf"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/macos/shell-integration" "$APP/Contents/Resources/shell-integration"
# Seal Info.plist and resources into the signature; ad-hoc is the ceiling without a Developer ID.
codesign --force --deep --sign - "$APP"
echo "$APP"
