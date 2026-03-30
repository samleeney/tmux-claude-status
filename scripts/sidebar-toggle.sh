#!/usr/bin/env bash

# Toggle the agent sidebar pane on/off.
# Called from a tmux keybinding registered in tmux-agent-status.tmux.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR_TITLE="agent-sidebar"

# Read configured width (with fallback chain)
width=$(tmux show-option -gqv "@agent-sidebar-width" 2>/dev/null)
[ -z "$width" ] && width=$(tmux show-option -gqv "@claude-sidebar-width" 2>/dev/null)
[ -z "$width" ] && width=40

# Find sidebar pane in the current window by title.
find_sidebar_in_window() {
    tmux list-panes -F '#{pane_id} #{pane_title}' 2>/dev/null | \
        while read -r pid title; do
            if [ "$title" = "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

# Find sidebar pane anywhere in the current session.
find_sidebar_in_session() {
    tmux list-panes -s -F '#{pane_id} #{pane_title}' 2>/dev/null | \
        while read -r pid title; do
            if [ "$title" = "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

# Find the file manager sidebar (narrow left-edge pane, not ours).
find_file_sidebar() {
    tmux list-panes -F '#{pane_id} #{pane_left} #{pane_width} #{pane_title}' 2>/dev/null | \
        while read -r pid left w title; do
            if [ "$left" = "0" ] && [ "$w" -le 60 ] && [ "$title" != "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

existing=$(find_sidebar_in_window)

if [ -n "$existing" ]; then
    # Sidebar visible in current window — toggle off.
    tmux kill-pane -t "$existing"
else
    # Kill any sidebar in other windows so we don't accumulate orphans.
    other=$(find_sidebar_in_session)
    [ -n "$other" ] && tmux kill-pane -t "$other" 2>/dev/null

    file_sidebar=$(find_file_sidebar)

    if [ -n "$file_sidebar" ]; then
        # File manager is open — split below it (inherits the same width).
        new_pane=$(tmux split-window -v -t "$file_sidebar" \
            -PF '#{pane_id}' "$CURRENT_DIR/sidebar.sh")
    else
        # No file manager — create a left-side split.
        leftmost=$(tmux list-panes -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
        new_pane=$(tmux split-window -hbl "$width" -t "$leftmost" \
            -PF '#{pane_id}' "$CURRENT_DIR/sidebar.sh")
    fi

    # Tag the pane so we can find it later.
    tmux select-pane -t "$new_pane" -T "$SIDEBAR_TITLE"
fi
