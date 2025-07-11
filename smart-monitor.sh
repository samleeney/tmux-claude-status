#!/usr/bin/env bash

# Smart monitoring daemon that only runs when SSH sessions exist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-claude-status"
DAEMON_PID_FILE="$STATUS_DIR/smart-monitor.pid"

# Function to check if any SSH sessions exist
has_ssh_sessions() {
    # Check if any tmux session has SSH panes
    tmux list-sessions -F "#{session_name}" 2>/dev/null | while read -r session; do
        if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
            return 0
        fi
    done
    # Also check for known SSH sessions like reachgpu
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -q "^reachgpu$"
}

# Function to check if daemon should keep running
should_run() {
    # Run if tmux is active and has SSH sessions
    tmux list-sessions >/dev/null 2>&1 && has_ssh_sessions
}

# Function to update SSH session status
update_ssh_status() {
    # Update reachgpu status
    ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET \
        reachgpu "cat ~/.cache/tmux-claude-status/reachgpu.status" 2>/dev/null \
        > "$STATUS_DIR/reachgpu-remote.status" 2>/dev/null || echo "" > "$STATUS_DIR/reachgpu-remote.status"
}

# Function to start monitoring
start_monitor() {
    if [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        # Already running
        return 0
    fi
    
    (
        while should_run; do
            update_ssh_status
            sleep 5
        done
        # Clean up when done
        rm -f "$DAEMON_PID_FILE"
    ) &
    
    echo $! > "$DAEMON_PID_FILE"
}

# Function to stop monitoring
stop_monitor() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
        fi
        rm -f "$DAEMON_PID_FILE"
    fi
}

# Function to check status
check_status() {
    if [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "Smart monitor running (PID: $(cat "$DAEMON_PID_FILE"))"
        return 0
    else
        echo "Smart monitor not running"
        return 1
    fi
}

# Main command handling
case "${1:-start}" in
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    status)
        check_status
        ;;
    update)
        update_ssh_status
        ;;
    *)
        echo "Usage: $0 {start|stop|status|update}"
        exit 1
        ;;
esac