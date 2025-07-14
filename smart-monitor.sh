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

# Function to check wait timers and move expired sessions back to done
check_wait_timers() {
    local wait_dir="$STATUS_DIR/wait"
    [ ! -d "$wait_dir" ] && return
    
    local current_time=$(date +%s)
    local notification_sound="/usr/share/sounds/freedesktop/stereo/complete.oga"
    
    for wait_file in "$wait_dir"/*.wait; do
        [ ! -f "$wait_file" ] && continue
        
        local session_name=$(basename "$wait_file" .wait)
        local expiry_time=$(cat "$wait_file" 2>/dev/null)
        
        if [ -n "$expiry_time" ] && [ "$current_time" -ge "$expiry_time" ]; then
            # Timer expired, move back to done
            echo "done" > "$STATUS_DIR/${session_name}.status" 2>/dev/null
            echo "done" > "$STATUS_DIR/${session_name}-remote.status" 2>/dev/null
            
            # Remove wait file
            rm -f "$wait_file"
            
            # Play notification sound (same as when Claude finishes)
            if command -v paplay >/dev/null 2>&1 && [ -f "$notification_sound" ]; then
                paplay "$notification_sound" 2>/dev/null &
            elif command -v afplay >/dev/null 2>&1; then
                afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
            elif command -v beep >/dev/null 2>&1; then
                beep 2>/dev/null &
            else
                echo -ne '\a'
            fi
        fi
    done
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
            local remote_status=$(cat "$temp_file")
            # If remote Claude is working, cancel local wait mode
            if [ "$remote_status" = "working" ] && [ -f "$STATUS_DIR/wait/reachgpu.wait" ]; then
                rm -f "$STATUS_DIR/wait/reachgpu.wait"
            fi
            # Don't overwrite local wait status at all
            if [ ! -f "$STATUS_DIR/wait/reachgpu.wait" ]; then
                mv "$temp_file" "$STATUS_DIR/reachgpu-remote.status"
            else
                rm -f "$temp_file"
            fi
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
            local remote_status=$(cat "$temp_file")
            # If remote Claude is working, cancel local wait mode
            if [ "$remote_status" = "working" ] && [ -f "$STATUS_DIR/wait/tig.wait" ]; then
                rm -f "$STATUS_DIR/wait/tig.wait"
            fi
            # Don't overwrite local wait status at all
            if [ ! -f "$STATUS_DIR/wait/tig.wait" ]; then
                mv "$temp_file" "$STATUS_DIR/tig-remote.status"
            else
                rm -f "$temp_file"
            fi
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
            local remote_status=$(cat "$temp_file")
            # If remote Claude is working, cancel local wait mode
            if [ "$remote_status" = "working" ] && [ -f "$STATUS_DIR/wait/l4-workstation.wait" ]; then
                rm -f "$STATUS_DIR/wait/l4-workstation.wait"
            fi
            # Don't overwrite local wait status at all
            if [ ! -f "$STATUS_DIR/wait/l4-workstation.wait" ]; then
                mv "$temp_file" "$STATUS_DIR/l4-workstation-remote.status"
            else
                rm -f "$temp_file"
            fi
        else
            rm -f "$temp_file"
        fi
    fi
    
    # ADD_SSH_SESSIONS_HERE
    
    # Check wait timers and move expired sessions back to done
    check_wait_timers
}

# Function to start monitoring
start_monitor() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local old_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            # Already running
            return 0
        else
            # Remove stale PID file
            rm -f "$DAEMON_PID_FILE"
        fi
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
