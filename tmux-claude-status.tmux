#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default key binding
default_key="s"
tmux_option_key="@claude-status-key"

# Get user configuration or use default
key=$(tmux show-option -gqv "$tmux_option_key")
[ -z "$key" ] && key="$default_key"

# Set up custom session switcher with Claude status (hook-based)
tmux bind-key "$key" display-popup -E -w 80% -h 70% "$CURRENT_DIR/scripts/hook-based-switcher.sh"

# Set up keybinding to switch to next done project (prefix + n)
tmux bind-key "n" run-shell "$CURRENT_DIR/scripts/next-done-project.sh"

# Set up keybinding to put session in wait mode (prefix + w)
tmux bind-key "w" run-shell "$CURRENT_DIR/scripts/wait-session.sh"

# Set up tmux status line integration
tmux set-option -g status-interval 1

# Check if our status is already in the status-right
current_status_right=$(tmux show-option -gqv status-right)
if ! echo "$current_status_right" | grep -q "status-line.sh"; then
    tmux set-option -ag status-right " #($CURRENT_DIR/scripts/status-line.sh)"
fi