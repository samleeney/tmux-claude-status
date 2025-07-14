#!/usr/bin/env bash

# Put current session in wait mode with a timer

STATUS_DIR="$HOME/.cache/tmux-claude-status"
WAIT_DIR="$STATUS_DIR/wait"
mkdir -p "$WAIT_DIR"

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

# Check if session has Claude
if ! has_claude_in_session "$current_session" && ! is_ssh_session "$current_session"; then
    tmux display-message "Session $current_session has no Claude running"
    exit 1
fi

# Prompt for wait time
tmux command-prompt -p "Wait time in minutes:" "run-shell 'echo %1 > $WAIT_DIR/$current_session.wait_time'"

# Wait for the input to be processed
sleep 0.5

# Check if wait time was provided
if [ ! -f "$WAIT_DIR/$current_session.wait_time" ]; then
    tmux display-message "Wait cancelled"
    exit 0
fi

wait_minutes=$(cat "$WAIT_DIR/$current_session.wait_time" 2>/dev/null)
rm -f "$WAIT_DIR/$current_session.wait_time"

# Validate input
if ! [[ "$wait_minutes" =~ ^[0-9]+$ ]] || [ "$wait_minutes" -eq 0 ]; then
    tmux display-message "Invalid wait time: $wait_minutes"
    exit 1
fi

# Calculate expiry time
expiry_time=$(($(date +%s) + (wait_minutes * 60)))

# Create wait file with expiry time
echo "$expiry_time" > "$WAIT_DIR/$current_session.wait"

# Set session status to wait
if is_ssh_session "$current_session"; then
    echo "wait" > "$STATUS_DIR/${current_session}-remote.status"
else
    echo "wait" > "$STATUS_DIR/${current_session}.status"
fi

tmux display-message "Session $current_session will wait for $wait_minutes minutes"