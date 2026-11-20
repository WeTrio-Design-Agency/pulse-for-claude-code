#!/bin/zsh
# Installs Pulse for Claude Code from ready-made files next to this script (no build tools needed):
#   ./Pulse for Claude Code.app and ./pulse-hook (or in the folder given as the first argument)
# Puts the app in ~/Applications, the hook in ~/.claude-pulse/bin, registers the hook in
# ~/.claude/settings.json (a backup is kept next to it), builds the history for the time
# estimate from past chats, and starts the app at login. Safe to run again.
set -euo pipefail
HERE="$(cd "${1:-$(dirname "$0")}" && pwd)"
PULSE="$HOME/.claude-pulse"
APP_DST="$HOME/Applications/Pulse for Claude Code.app"
AGENT="$HOME/Library/LaunchAgents/local.claude-pulse.plist"
BIN="$APP_DST/Contents/MacOS/ClaudePulse"

# Files that came in a downloaded zip are quarantined; macOS would refuse to run them.
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true

mkdir -p "$PULSE/bin" "$PULSE/events" "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/local.claude-pulse" 2>/dev/null || true
pkill -x ClaudePulse 2>/dev/null || true
sleep 0.5

rm -rf "$APP_DST" "$HOME/Applications/Claude Pulse.app"  # also the app of earlier builds
cp -R "$HERE/Pulse for Claude Code.app" "$APP_DST"
cp "$HERE/pulse-hook" "$PULSE/bin/pulse-hook.new" && mv "$PULSE/bin/pulse-hook.new" "$PULSE/bin/pulse-hook"
chmod +x "$PULSE/bin/pulse-hook" "$BIN"
xattr -dr com.apple.quarantine "$APP_DST" "$PULSE/bin/pulse-hook" 2>/dev/null || true

echo "Reading past chats for the time estimate (can take a minute)..."
"$BIN" --seed-history
"$BIN" --register-hooks install

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.claude-pulse</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Pulse for Claude Code installed and running."
