#!/usr/bin/env bash

# Toggle the agent sidebar pane on/off.
# Called from a tmux keybinding registered in tmux-agent-status.tmux.
# Optional arg: target window (e.g. "session:window"). Defaults to current.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR_TITLE="agent-sidebar"
TARGET="${1:-}"

# Read configured width.
width=$(tmux show-option -gqv "@agent-sidebar-width" 2>/dev/null)
[ -z "$width" ] && width=42

# Build -t flag for list-panes when a target is given.
target_flag=()
if [ -n "$TARGET" ]; then
    target_flag=(-t "$TARGET")
fi

# Find sidebar pane in the target window by title.
find_sidebar_in_window() {
    tmux list-panes "${target_flag[@]}" -F '#{pane_id} #{pane_title}' 2>/dev/null | \
        while read -r pid title; do
            if [ "$title" = "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

# Find the file manager sidebar (narrow left-edge pane, not ours).
find_file_sidebar() {
    tmux list-panes "${target_flag[@]}" -F '#{pane_id} #{pane_left} #{pane_width} #{pane_title}' 2>/dev/null | \
        while read -r pid left w title; do
            if [ "$left" = "0" ] && [ "$w" -le 60 ] && [ "$title" != "$SIDEBAR_TITLE" ]; then
                echo "$pid"
                return 0
            fi
        done
}

existing=$(find_sidebar_in_window)

if [ -n "$existing" ]; then
    # Sidebar visible in current window — focus it (don't kill).
    tmux select-pane -t "$existing"
else
    file_sidebar=$(find_file_sidebar)

    if [ -n "$file_sidebar" ]; then
        # File manager is open — split below it (inherits the same width).
        new_pane=$(tmux split-window -v -t "$file_sidebar" \
            -PF '#{pane_id}' "$CURRENT_DIR/sidebar.sh")
    else
        # No file manager — create a left-side split.
        leftmost=$(tmux list-panes "${target_flag[@]}" -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
        new_pane=$(tmux split-window -hbl "$width" -t "$leftmost" \
            -PF '#{pane_id}' "$CURRENT_DIR/sidebar.sh")
    fi

    # Tag the pane so we can find it later.
    tmux select-pane -t "$new_pane" -T "$SIDEBAR_TITLE"
fi
