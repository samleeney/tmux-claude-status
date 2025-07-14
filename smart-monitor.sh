#!/usr/bin/env bash

# Smart monitoring daemon that only runs when SSH sessions exist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-claude-status"
DAEMON_PID_FILE="$STATUS_DIR/smart-monitor.pid"

# Function to check if any SSH sessions exist
has_ssh_sessions() {
    # Check if any tmux session has SSH panes
    local found_ssh=false
    while read -r session; do
        if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
            found_ssh=true
            break
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)
    
    if [ "$found_ssh" = true ]; then
        return 0
    fi
    
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
    if tmux has-session -t reachgpu 2>/dev/null; then
        local temp_file="$STATUS_DIR/.reachgpu-remote.status.tmp"
        if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET \
            reachgpu "cat ~/.cache/tmux-claude-status/reachgpu.status 2>/dev/null || echo ''" \
            > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$STATUS_DIR/reachgpu-remote.status"
        else
            rm -f "$temp_file"
        fi
    fi
    
    # Update tig status
    if tmux has-session -t tig 2>/dev/null; then
        local temp_file="$STATUS_DIR/.tig-remote.status.tmp"
        if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET \
            nga100 "cat ~/.cache/tmux-claude-status/tig.status 2>/dev/null || echo ''" \
            > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$STATUS_DIR/tig-remote.status"
        else
            rm -f "$temp_file"
        fi
    fi
    
    # Update l4-workstation status
    if tmux has-session -t l4-workstation 2>/dev/null; then
        local temp_file="$STATUS_DIR/.l4-workstation-remote.status.tmp"
        if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET \
            l4-workstation "cat ~/.cache/tmux-claude-status/l4-workstation.status 2>/dev/null || echo ''" \
            > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$STATUS_DIR/l4-workstation-remote.status"
        else
            rm -f "$temp_file"
        fi
    fi
    
    # ADD_SSH_SESSIONS_HERE
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
            sleep 1
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
