#!/usr/bin/env bash

# Put current session in wait mode with a timer

STATUS_DIR="$HOME/.cache/tmux-claude-status"
WAIT_DIR="$STATUS_DIR/wait"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get current session
current_session=$(tmux display-message -p "#{session_name}")

# Check if session has Claude
has_claude_in_session() {
    local session="$1"
    while IFS=: read -r pane_id pane_pid; do
        if pgrep -P "$pane_pid" -f "claude" >/dev/null 2>&1; then
            return 0
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)
    return 1
}

# Check if session is SSH
is_ssh_session() {
    local session="$1"
    if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
        return 0
    fi
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if session has Claude or is SSH session
if ! has_claude_in_session "$current_session" && ! is_ssh_session "$current_session"; then
    # Also check if session has a status file (might be from a finished Claude)
    if [ ! -f "$STATUS_DIR/${current_session}.status" ] && [ ! -f "$STATUS_DIR/${current_session}-remote.status" ]; then
        tmux display-message "Session $current_session has no Claude running"
        exit 1
    fi
fi

# Prompt for wait time using command-prompt
# This will call our handler script with the session name and wait time
tmux command-prompt -p "Wait time in minutes:" "run-shell '$SCRIPT_DIR/wait-session-handler.sh \"$current_session\" %1'"