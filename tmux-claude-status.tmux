#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default key binding
default_key="s"
tmux_option_key="@claude-status-key"

# Get user configuration or use default
key=$(tmux show-option -gqv "$tmux_option_key")
[ -z "$key" ] && key="$default_key"

# Set up custom session switcher with Claude status
tmux bind-key "$key" display-popup -E -w 80% -h 70% "$CURRENT_DIR/scripts/simple-session-switcher.sh"

# Optional: Start background status monitor (commented out for now)
# pkill -f "status-monitor.*\.sh" 2>/dev/null
# "$CURRENT_DIR/scripts/status-monitor-v2.sh" > /dev/null 2>&1 &