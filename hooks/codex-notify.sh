#!/usr/bin/env bash

# Codex CLI notify hook for tmux-agent-status
# Config: notify = ["path/to/codex-notify.sh"] in ~/.codex/config.toml
# Receives JSON as last CLI argument
#
# Limitation: Codex CLI lacks full event hooks (only "notify" for turn-complete).
# "Working" detection is handled by process polling in status-line.sh.
# Tracking issue: https://github.com/openai/codex/issues/2109

STATUS_DIR="$HOME/.cache/tmux-agent-status"
mkdir -p "$STATUS_DIR"

TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
[ -z "$TMUX_SESSION" ] && exit 0

echo "done" > "$STATUS_DIR/${TMUX_SESSION}.status"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &

exit 0
