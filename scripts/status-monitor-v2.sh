#!/usr/bin/env bash

# More efficient status monitor using tmux hooks

STATUS_DIR="/tmp/tmux-claude-status"
mkdir -p "$STATUS_DIR"

# Function to update session status
update_session_status() {
    local session="$1"
    local has_claude=false
    local is_working=false
    
    # Get all pane processes in the session
    while IFS=: read -r pane_id pane_pid; do
        # Check for claude process
        if pgrep -P "$pane_pid" -f "node.*claude" >/dev/null 2>&1; then
            has_claude=true
            
            # Get claude process info
            local claude_info=$(ps -p $(pgrep -P "$pane_pid" -f "node.*claude" | head -1) -o pid=,%cpu=,state= 2>/dev/null)
            if [ -n "$claude_info" ]; then
                local cpu=$(echo "$claude_info" | awk '{print $2}')
                local state=$(echo "$claude_info" | awk '{print $3}')
                
                # Check if working based on CPU or state
                if (( $(echo "$cpu > 0.5" | bc -l 2>/dev/null || echo 0) )); then
                    is_working=true
                    break
                elif [[ "$state" != "S"* ]]; then
                    is_working=true
                    break
                fi
            fi
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)
    
    # Update status file
    if $has_claude; then
        if $is_working; then
            echo "working" > "$STATUS_DIR/${session}.status"
        else
            echo "done" > "$STATUS_DIR/${session}.status"
        fi
    else
        rm -f "$STATUS_DIR/${session}.status"
    fi
}

# Update all sessions on startup
tmux list-sessions -F "#{session_name}" 2>/dev/null | while read -r session; do
    update_session_status "$session"
done

# Main monitoring loop
while true; do
    # Update active sessions only
    active_sessions=$(tmux list-sessions -F "#{session_name}:#{?session_attached,attached,}" 2>/dev/null | grep "attached" | cut -d: -f1)
    
    for session in $active_sessions; do
        update_session_status "$session"
    done
    
    # Also check sessions with existing status files
    for status_file in "$STATUS_DIR"/*.status; do
        [ -f "$status_file" ] || continue
        session=$(basename "$status_file" .status)
        if tmux has-session -t "$session" 2>/dev/null; then
            update_session_status "$session"
        else
            rm -f "$status_file"
        fi
    done
    
    sleep 3
done