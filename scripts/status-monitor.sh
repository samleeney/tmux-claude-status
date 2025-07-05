#!/usr/bin/env bash

# Create status directory
STATUS_DIR="/tmp/tmux-claude-status"
mkdir -p "$STATUS_DIR"

# Function to check if Claude is working in a pane
check_claude_working() {
    local pane_pid="$1"
    local pane_tty="$2"
    
    # Check if claude process exists under this pane
    if pgrep -P "$pane_pid" -f "claude" > /dev/null 2>&1; then
        # Get the claude process
        local claude_pid=$(pgrep -P "$pane_pid" -f "claude" | head -1)
        
        if [ -n "$claude_pid" ]; then
            # Check CPU usage to determine if actively working
            local cpu_usage=$(ps -p "$claude_pid" -o %cpu= 2>/dev/null | tr -d ' ')
            
            # If CPU usage is above threshold, it's working
            if [ -n "$cpu_usage" ] && (( $(echo "$cpu_usage > 0.5" | bc -l 2>/dev/null || echo 0) )); then
                return 0  # Working
            else
                # Check if process is waiting for input (done state)
                local state=$(ps -p "$claude_pid" -o state= 2>/dev/null | tr -d ' ')
                if [[ "$state" == "S"* ]]; then
                    return 1  # Done/waiting
                else
                    return 0  # Working
                fi
            fi
        fi
    fi
    
    return 2  # No Claude process
}

# Monitor loop
while true; do
    # Get all sessions
    tmux list-sessions -F "#{session_name}" 2>/dev/null | while read -r session; do
        local has_claude=false
        local claude_working=false
        
        # Check all panes in session
        tmux list-panes -s -t "$session" -F "#{pane_pid}:#{pane_tty}" 2>/dev/null | while IFS=: read -r pane_pid pane_tty; do
            if check_claude_working "$pane_pid" "$pane_tty"; then
                has_claude=true
                claude_working=true
                break
            elif [ $? -eq 1 ]; then
                has_claude=true
            fi
        done
        
        # Update status file
        if $has_claude; then
            if $claude_working; then
                echo "working" > "$STATUS_DIR/${session}.status"
            else
                echo "done" > "$STATUS_DIR/${session}.status"
            fi
        else
            # Remove status file if no Claude process
            rm -f "$STATUS_DIR/${session}.status"
        fi
    done
    
    # Sleep before next check
    sleep 2
done