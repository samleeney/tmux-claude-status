#!/usr/bin/env bash

# Handler for wait session - called with wait time as argument

STATUS_DIR="$HOME/.cache/tmux-claude-status"
WAIT_DIR="$STATUS_DIR/wait"
mkdir -p "$WAIT_DIR"

current_session="$1"
wait_minutes="$2"

# Validate input
if ! [[ "$wait_minutes" =~ ^[0-9]+$ ]] || [ "$wait_minutes" -eq 0 ]; then
    tmux display-message "Invalid wait time: $wait_minutes"
    exit 1
fi

# Calculate expiry time
expiry_time=$(($(date +%s) + (wait_minutes * 60)))

# Create wait file with expiry time FIRST (before changing status)
echo "$expiry_time" > "$WAIT_DIR/$current_session.wait"

# Small delay to ensure wait file is written
sync

# Set session status to wait
# Check if it's an SSH session by looking for remote status file
if [ -f "$STATUS_DIR/${current_session}-remote.status" ]; then
    echo "wait" > "$STATUS_DIR/${current_session}-remote.status"
else
    echo "wait" > "$STATUS_DIR/${current_session}.status"
fi

tmux display-message "Session $current_session will wait for $wait_minutes minutes"

# Switch to next done session or show completion message
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"

if [ -f "$NEXT_DONE_SCRIPT" ]; then
    # Try to switch to next done session (excluding current session)
    if ! bash "$NEXT_DONE_SCRIPT" "$current_session" 2>/dev/null; then
        # No done sessions available
        tmux display-message "✓ All done! No more sessions to work on."
    fi
else
    tmux display-message "Wait mode activated"
fi