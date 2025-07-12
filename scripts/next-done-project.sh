#!/usr/bin/env bash

# Find and switch to the next 'done' project

STATUS_DIR="$HOME/.cache/tmux-claude-status"

# Function to check if Claude is in a session
has_claude_in_session() {
    local session="$1"
    
    while IFS=: read -r pane_id pane_pid; do
        if pgrep -P "$pane_pid" -f "claude" >/dev/null 2>&1; then
            return 0
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)
    
    return 1
}

# Function to check if session is SSH
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

# Function to get Claude status
get_claude_status() {
    local session="$1"
    
    if [ "$session" = "reachgpu" ]; then
        local cached_status="$STATUS_DIR/reachgpu-remote.status"
        if [ -f "$cached_status" ]; then
            cat "$cached_status" 2>/dev/null
            return
        fi
    fi
    
    local status_file="$STATUS_DIR/${session}.status"
    if [ -f "$status_file" ]; then
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get current session
current_session=$(tmux display-message -p "#{session_name}")

# Collect all done sessions
done_sessions=()
while IFS=: read -r name windows attached; do
    # Check if Claude is present
    local claude_status=$(get_claude_status "$name")
    local has_claude=false
    
    if has_claude_in_session "$name"; then
        has_claude=true
    elif [ -n "$claude_status" ]; then
        has_claude=true
    fi
    
    if [ "$has_claude" = true ]; then
        [ -z "$claude_status" ] && claude_status="done"
        
        if [ "$claude_status" = "done" ]; then
            done_sessions+=("$name")
        fi
    fi
done < <(tmux list-sessions -F "#{session_name}:#{session_windows}:#{?session_attached,(attached),}" 2>/dev/null || echo "")

# If no done sessions, exit
if [ ${#done_sessions[@]} -eq 0 ]; then
    tmux display-message "No done projects found"
    exit 0
fi

# Find current session index in done sessions
current_index=-1
for i in "${!done_sessions[@]}"; do
    if [ "${done_sessions[$i]}" = "$current_session" ]; then
        current_index=$i
        break
    fi
done

# Calculate next index
if [ $current_index -eq -1 ]; then
    # Current session not in done list, switch to first done session
    next_session="${done_sessions[0]}"
else
    # Switch to next done session (wrap around)
    next_index=$(( (current_index + 1) % ${#done_sessions[@]} ))
    next_session="${done_sessions[$next_index]}"
fi

# Switch to the next done session
tmux switch-client -t "$next_session"
tmux display-message "Switched to next done project: $next_session"