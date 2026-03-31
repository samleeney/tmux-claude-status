#!/usr/bin/env bash

# Handler for wait session - called with target and wait time as arguments.
# Target is either a session name (session-level wait) or "session:pane_id" (pane-level).

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
mkdir -p "$WAIT_DIR" "$PANE_DIR"

target="$1"
wait_minutes="$2"

# Validate input
if ! [[ "$wait_minutes" =~ ^[0-9]+$ ]] || [ "$wait_minutes" -eq 0 ]; then
    tmux display-message "Invalid wait time: $wait_minutes"
    exit 1
fi

expiry_time=$(($(date +%s) + (wait_minutes * 60)))

# Determine if this is a pane-level or session-level wait.
if [[ "$target" == *:* ]]; then
    # Pane-level wait: "session:pane_id"
    session="${target%%:*}"
    pane_id="${target#*:}"

    echo "$expiry_time" > "$WAIT_DIR/${session}_${pane_id}.wait"
    sync
    rm -f "$PARKED_DIR/${session}_${pane_id}.parked"
    echo "wait" > "$PANE_DIR/${session}_${pane_id}.status"

    # Update session-level status to reflect the wait
    echo "wait" > "$STATUS_DIR/${session}.status"

    tmux display-message "Pane $pane_id will wait for $wait_minutes minutes"
else
    # Session-level wait
    session="$target"

    echo "$expiry_time" > "$WAIT_DIR/$session.wait"
    sync

    # Wait overrides parked state
    rm -f "$PARKED_DIR/$session.parked"
    rm -f "$PARKED_DIR/${session}_"*.parked 2>/dev/null

    if [ -f "$STATUS_DIR/${session}-remote.status" ]; then
        echo "wait" > "$STATUS_DIR/${session}-remote.status"
    else
        echo "wait" > "$STATUS_DIR/${session}.status"
    fi

    # Create per-pane wait files and update pane statuses
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        echo "$expiry_time" > "$WAIT_DIR/${session}_${pid}.wait"
        echo "wait" > "$PANE_DIR/${session}_${pid}.status"
        rm -f "$PARKED_DIR/${session}_${pid}.parked" 2>/dev/null
    done < <(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)

    tmux display-message "Session $session will wait for $wait_minutes minutes"
fi

# Switch to next done session
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"
if [ -f "$NEXT_DONE_SCRIPT" ]; then
    bash "$NEXT_DONE_SCRIPT" "$session" 2>/dev/null || true
fi
