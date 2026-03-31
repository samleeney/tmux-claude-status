#!/usr/bin/env bash

# Park the current session so it stays in the switcher but drops out of the toolbar.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
mkdir -p "$PARKED_DIR"

current_session=$(tmux display-message -p "#{session_name}")

if ! has_agent_in_session "$current_session" && ! is_ssh_session "$current_session"; then
    if [ ! -f "$STATUS_DIR/${current_session}.status" ] && [ ! -f "$STATUS_DIR/${current_session}-remote.status" ]; then
        tmux display-message "Session $current_session has no agent state to park"
        exit 1
    fi
fi

rm -f "$WAIT_DIR/$current_session.wait"
: > "$PARKED_DIR/$current_session.parked"

if is_ssh_session "$current_session"; then
    echo "parked" > "$STATUS_DIR/${current_session}-remote.status"
else
    echo "parked" > "$STATUS_DIR/${current_session}.status"
fi

# Also update per-pane status files so sidebar pane-level state stays consistent
PANE_DIR="$STATUS_DIR/panes"
for pf in "$PANE_DIR/${current_session}_"*.status; do
    [ -f "$pf" ] && echo "parked" > "$pf"
done

NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"
if [ -f "$NEXT_DONE_SCRIPT" ]; then
    if ! bash "$NEXT_DONE_SCRIPT" "$current_session" 2>/dev/null; then
        tmux display-message "Session $current_session parked for later"
    fi
else
    tmux display-message "Session $current_session parked for later"
fi
