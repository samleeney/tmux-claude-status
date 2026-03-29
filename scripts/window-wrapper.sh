#!/usr/bin/env bash

# Wrapper for window-based session switching (alternative to popup).
# Opens the switcher in a tmux window and cleans up after selection.
# Inspired by ianchesal/tmux-claude-status.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/hook-based-switcher.sh"

# If we're still in the switcher window, close it
current_window=$(tmux display-message -p '#{window_name}')
if [ "$current_window" = "agent-status" ]; then
    tmux kill-window
fi
