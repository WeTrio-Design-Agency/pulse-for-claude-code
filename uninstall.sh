#!/bin/zsh
# Removes Pulse for Claude Code: hook entries, login item, app. Keeps ~/.claude-pulse/history.json.
set -uo pipefail
BIN="$HOME/Applications/Pulse for Claude Code.app/Contents/MacOS/ClaudePulse"
[[ -x "$BIN" ]] || BIN="$HOME/Applications/Claude Pulse.app/Contents/MacOS/ClaudePulse"
[[ -x "$BIN" ]] && "$BIN" --register-hooks uninstall
launchctl bootout "gui/$(id -u)/local.claude-pulse" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.claude-pulse.plist"
pkill -x ClaudePulse 2>/dev/null
rm -rf "$HOME/Applications/Pulse for Claude Code.app" "$HOME/Applications/Claude Pulse.app" "$HOME/.claude-pulse/bin" "$HOME/.claude-pulse/events"
echo "Pulse for Claude Code removed."
