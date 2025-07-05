#!/usr/bin/env bash

# Alternative method to get Claude status by checking process activity
# This can be called manually or integrated into other scripts

session_name="${1:-$(tmux display-message -p '#{session_name}')}"

# Function to check Claude process in a pane
check_pane_for_claude() {
    local pane_id="$1"
    local pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}')
    
    # Find claude process under this pane
    local claude_pids=$(pgrep -P "$pane_pid" -f "node.*claude" 2>/dev/null)
    
    if [ -n "$claude_pids" ]; then
        for pid in $claude_pids; do
            # Check if process is actively using CPU
            local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
            local state=$(ps -p "$pid" -o state= 2>/dev/null | tr -d ' ')
            
            # Determine status based on state and CPU usage
            if [ -n "$cpu" ] && [ -n "$state" ]; then
                if (( $(echo "$cpu > 1.0" | bc -l 2>/dev/null || echo 0) )); then
                    echo "working"
                    return 0
                elif [[ "$state" == "S"* ]]; then
                    # Check if there's recent output (last 5 seconds)
                    local last_output=$(tmux capture-pane -p -t "$pane_id" -S -5 | grep -v "^$" | tail -1)
                    if [ -n "$last_output" ]; then
                        # Simple heuristic: if last line contains certain patterns, it's likely working
                        if echo "$last_output" | grep -qE "(Thinking|Processing|Analyzing|Running|Executing|Creating|Writing|Reading)"; then
                            echo "working"
                            return 0
                        fi
                    fi
                    echo "done"
                    return 0
                fi
            fi
        done
    fi
    
    return 1
}

# Check all panes in the session
status=""
tmux list-panes -t "$session_name" -F "#{pane_id}" 2>/dev/null | while read -r pane_id; do
    pane_status=$(check_pane_for_claude "$pane_id")
    if [ -n "$pane_status" ]; then
        status="$pane_status"
        # If any pane is working, the session is working
        if [ "$pane_status" = "working" ]; then
            echo "$pane_status"
            exit 0
        fi
    fi
done

# If we found Claude but no panes are working, it's done
if [ -n "$status" ]; then
    echo "done"
else
    echo ""
fi