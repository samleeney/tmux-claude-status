#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default key bindings
default_switcher_key="S"
default_next_done_key="N"
default_wait_key="W"

# Get user configuration or use defaults
switcher_key=$(tmux show-option -gqv "@claude-status-key")
next_done_key=$(tmux show-option -gqv "@claude-next-done-key")
wait_key=$(tmux show-option -gqv "@claude-wait-key")

[ -z "$switcher_key" ] && switcher_key="$default_switcher_key"
[ -z "$next_done_key" ] && next_done_key="$default_next_done_key"
[ -z "$wait_key" ] && wait_key="$default_wait_key"

# Set up custom session switcher with Claude status (hook-based)
tmux bind-key "$switcher_key" display-popup -E -w 80% -h 70% "$CURRENT_DIR/scripts/hook-based-switcher.sh"

# Set up keybinding to switch to next done project
tmux bind-key "$next_done_key" run-shell "$CURRENT_DIR/scripts/next-done-project.sh"

# Set up keybinding to put session in wait mode
tmux bind-key "$wait_key" run-shell "$CURRENT_DIR/scripts/wait-session.sh"

# Set up tmux status line integration
tmux set-option -g status-interval 1

# Check if our status is already in the status-right
current_status_right=$(tmux show-option -gqv status-right)
if ! echo "$current_status_right" | grep -q "status-line.sh"; then
    tmux set-option -ag status-right " #($CURRENT_DIR/scripts/status-line.sh)"
fi

# Set up daemon monitor to ensure smart-monitor is always running
# Start daemon monitor on session created
tmux set-hook -g session-created "run-shell '$CURRENT_DIR/scripts/daemon-monitor.sh'"

# Also start it now if tmux is already running
if tmux list-sessions >/dev/null 2>&1; then
    "$CURRENT_DIR/scripts/daemon-monitor.sh" >/dev/null 2>&1
fi
