#!/usr/bin/env bash

# Put current session in wait mode with a timer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"

# Get current session
current_session=$(tmux display-message -p "#{session_name}")

# Check if session has an agent or is SSH session
if ! has_agent_in_session "$current_session" && ! is_ssh_session "$current_session"; then
    # Also check if session has a status file (might be from a finished agent)
    if [ ! -f "$STATUS_DIR/${current_session}.status" ] && [ ! -f "$STATUS_DIR/${current_session}-remote.status" ]; then
        tmux display-message "Session $current_session has no agent running"
        exit 1
    fi
fi

# Prompt for wait time using command-prompt
# This will call our handler script with the session name and wait time
tmux command-prompt -p "Wait time in minutes:" "run-shell '$SCRIPT_DIR/wait-session-handler.sh \"$current_session\" %1'"
