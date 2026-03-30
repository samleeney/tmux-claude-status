#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One-time cache directory migration
OLD_DIR="$HOME/.cache/tmux-claude-status"
NEW_DIR="$HOME/.cache/tmux-agent-status"
if [ -d "$OLD_DIR" ] && [ ! -d "$NEW_DIR" ]; then
    mv "$OLD_DIR" "$NEW_DIR"
fi

# Default key bindings
default_switcher_key="S"
default_next_done_key="N"
default_wait_key="W"
default_park_key="p"

# Get user configuration or use defaults (check new @agent-* first, fall back to @claude-*)
switcher_key=$(tmux show-option -gqv "@agent-status-key")
[ -z "$switcher_key" ] && switcher_key=$(tmux show-option -gqv "@claude-status-key")
next_done_key=$(tmux show-option -gqv "@agent-next-done-key")
[ -z "$next_done_key" ] && next_done_key=$(tmux show-option -gqv "@claude-next-done-key")
wait_key=$(tmux show-option -gqv "@agent-wait-key")
[ -z "$wait_key" ] && wait_key=$(tmux show-option -gqv "@claude-wait-key")
park_key=$(tmux show-option -gqv "@agent-park-key")
[ -z "$park_key" ] && park_key=$(tmux show-option -gqv "@claude-park-key")

[ -z "$switcher_key" ] && switcher_key="$default_switcher_key"
[ -z "$next_done_key" ] && next_done_key="$default_next_done_key"
[ -z "$wait_key" ] && wait_key="$default_wait_key"
[ -z "$park_key" ] && park_key="$default_park_key"

# Switcher style: "popup" (fzf only), "sidebar" (sidebar only), or "both" (default)
switcher_style=$(tmux show-option -gqv "@agent-switcher-style")
[ -z "$switcher_style" ] && switcher_style="both"

# Sidebar key (used in "both" mode; in "sidebar" mode the main switcher key is used)
sidebar_key=$(tmux show-option -gqv "@agent-sidebar-key")
[ -z "$sidebar_key" ] && sidebar_key=$(tmux show-option -gqv "@claude-sidebar-key")
[ -z "$sidebar_key" ] && sidebar_key="o"

case "$switcher_style" in
    popup)
        tmux bind-key "$switcher_key" display-popup -E -w 80% -h 70% "$CURRENT_DIR/scripts/sidebar.sh --preview"
        ;;
    sidebar)
        tmux bind-key "$switcher_key" run-shell "$CURRENT_DIR/scripts/sidebar-toggle.sh"
        ;;
    both|*)
        tmux bind-key "$switcher_key" display-popup -E -w 80% -h 70% "$CURRENT_DIR/scripts/sidebar.sh --preview"
        tmux bind-key "$sidebar_key" run-shell "$CURRENT_DIR/scripts/sidebar-toggle.sh"
        ;;
esac

# Set up keybinding to switch to next done project
tmux bind-key "$next_done_key" run-shell "$CURRENT_DIR/scripts/next-done-project.sh"

# Set up keybinding to put session in wait mode
tmux bind-key "$wait_key" run-shell "$CURRENT_DIR/scripts/wait-session.sh"

# Set up keybinding to park a session for later
tmux bind-key "$park_key" run-shell "$CURRENT_DIR/scripts/park-session.sh"

# Detect iTerm2 Control Mode (tmux -CC) and skip status polling / daemons
# to avoid interfering with the control protocol. Keybindings above are fine.
control_mode=$(tmux display-message -p '#{client_control_mode}' 2>/dev/null)
if [ "$control_mode" = "1" ]; then
    exit 0
fi

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

# Auto-create sidebar in new sessions (small delay so the session is ready)
tmux set-hook -ga session-created "run-shell -b 'sleep 0.5 && $CURRENT_DIR/scripts/sidebar-toggle.sh'"

# Also start it now if tmux is already running
if tmux list-sessions >/dev/null 2>&1; then
    "$CURRENT_DIR/scripts/daemon-monitor.sh" >/dev/null 2>&1

    # Create sidebar in all existing sessions that don't have one
    for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        has_sidebar=$(tmux list-panes -t "$sess" -F '#{pane_title}' 2>/dev/null | grep -c "agent-sidebar")
        if [ "$has_sidebar" -eq 0 ]; then
            tmux run-shell -t "$sess" -b "$CURRENT_DIR/scripts/sidebar-toggle.sh" 2>/dev/null
        fi
    done
fi
