#!/bin/zsh
# Builds build/Pulse for Claude Code.app and build/pulse-hook as universal binaries (Apple Silicon + Intel)
# with the Command Line Tools only (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
APP="$OUT/Pulse for Claude Code.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

for ARCH in arm64 x86_64; do
  FLAGS=(-O -swift-version 5 -target $ARCH-apple-macosx14.0)
  swiftc "${FLAGS[@]}" Sources/Hook/main.swift -o "$OUT/obj/pulse-hook-$ARCH"
  swiftc "${FLAGS[@]}" Sources/App/*.swift -o "$OUT/obj/ClaudePulse-$ARCH"
done
lipo -create "$OUT/obj/pulse-hook-arm64" "$OUT/obj/pulse-hook-x86_64" -output "$OUT/pulse-hook"
lipo -create "$OUT/obj/ClaudePulse-arm64" "$OUT/obj/ClaudePulse-x86_64" -output "$APP/Contents/MacOS/ClaudePulse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --force --sign - "$OUT/pulse-hook" >/dev/null 2>&1
echo "built: $APP, $OUT/pulse-hook"
