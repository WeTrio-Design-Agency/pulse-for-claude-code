#!/bin/zsh
# Builds dist/Pulse-for-Claude-Code.zip
# (ready-made app, installer, source) for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
PKG=dist/Pulse-for-Claude-Code
rm -rf "$PKG" dist/Pulse-for-Claude-Code.zip
mkdir -p "$PKG/source"
cp -R "build/Pulse for Claude Code.app" "$PKG/"
cp build/pulse-hook "$PKG/"
cp scripts/install-prebuilt.sh "$PKG/Install.command"
cp uninstall.sh "$PKG/Uninstall.command"
chmod +x "$PKG"/*.command
cp README.md LICENSE "$PKG/"
# Source: everything tracked in git.
git ls-files | while read -r f; do
  mkdir -p "$PKG/source/$(dirname "$f")"
  cp "$f" "$PKG/source/$f"
done
# No Finder metadata (._ files, __MACOSX) in the archive.
(cd dist && COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent Pulse-for-Claude-Code Pulse-for-Claude-Code.zip)
echo "packed: dist/Pulse-for-Claude-Code.zip ($(du -h dist/Pulse-for-Claude-Code.zip | cut -f1))"
