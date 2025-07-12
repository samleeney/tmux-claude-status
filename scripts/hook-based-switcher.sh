#!/usr/bin/env bash

# Hook-based session switcher that reads status from files

STATUS_DIR="$HOME/.cache/tmux-claude-status"

# Function to check if Claude is in a session (actually running, not just has status file)
has_claude_in_session() {
    local session="$1"
    
    # Check all panes in the session for claude processes
    while IFS=: read -r pane_id pane_pid; do
        if pgrep -P "$pane_pid" -f "claude" >/dev/null 2>&1; then
            return 0  # Found Claude process
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)
    
    return 1  # No Claude process found
}

# Function to check if session is SSH by examining panes
is_ssh_session() {
    local session="$1"
    # Check if any pane in the session is running SSH
    if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
        return 0
    fi
    # Simple fallback: check if session name matches known SSH hosts
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}


# Function to get SSH host for session
get_ssh_host() {
    local session="$1"
    # For now, if it's an SSH session, assume the session name is the host
    # This is simple and works for most cases where session names match SSH config
    if is_ssh_session "$session"; then
        echo "$session"
    fi
}

# Function to get Claude status from hook files
get_claude_status() {
    local session="$1"
    
    # Check for remote status file first (for SSH sessions)
    local remote_status="$STATUS_DIR/${session}-remote.status"
    if [ -f "$remote_status" ]; then
        cat "$remote_status" 2>/dev/null
        return
    fi
    
    # Check local status files
    local status_file="$STATUS_DIR/${session}.status"
    if [ -f "$status_file" ]; then
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get all sessions with formatted output
get_sessions_with_status() {
    local working_sessions=()
    local done_sessions=()
    local no_claude_sessions=()
    
    # Collect all sessions into arrays
    while IFS=: read -r name windows attached; do
        local formatted_line=""
        
        # Check if it's an SSH session
        local ssh_indicator=""
        if is_ssh_session "$name"; then
            ssh_indicator="[🌐 ssh]"
        fi
        
        # Check if Claude is present (local) or if we have remote status (SSH)
        local claude_status=$(get_claude_status "$name")
        local has_claude=false
        
        if has_claude_in_session "$name"; then
            has_claude=true
        elif [ -n "$claude_status" ] && is_ssh_session "$name"; then
            # SSH session with remote status
            has_claude=true
        else
            # Clean up stale status file if Claude is not running
            if [ -n "$claude_status" ] && ! is_ssh_session "$name"; then
                rm -f "$STATUS_DIR/${name}.status" 2>/dev/null
            fi
        fi
        
        if [ "$has_claude" = true ]; then
            # Default to "done" if no status file exists
            [ -z "$claude_status" ] && claude_status="done"
            
            if [ "$claude_status" = "working" ]; then
                if [ -n "$ssh_indicator" ]; then
                    formatted_line=$(printf "%-20s %2s windows %-12s %s [⚡ working]" "$name" "$windows" "$attached" "$ssh_indicator")
                else
                    formatted_line=$(printf "%-20s %2s windows %-12s [⚡ working]" "$name" "$windows" "$attached")
                fi
                working_sessions+=("$formatted_line")
            else
                if [ -n "$ssh_indicator" ]; then
                    formatted_line=$(printf "%-20s %2s windows %-12s %s [✓ done]" "$name" "$windows" "$attached" "$ssh_indicator")
                else
                    formatted_line=$(printf "%-20s %2s windows %-12s [✓ done]" "$name" "$windows" "$attached")
                fi
                done_sessions+=("$formatted_line")
            fi
        else
            if [ -n "$ssh_indicator" ]; then
                formatted_line=$(printf "%-20s %2s windows %-12s %s [no claude]" "$name" "$windows" "$attached" "$ssh_indicator")
            else
                formatted_line=$(printf "%-20s %2s windows %-12s [no claude]" "$name" "$windows" "$attached")
            fi
            no_claude_sessions+=("$formatted_line")
        fi
    done < <(tmux list-sessions -F "#{session_name}:#{session_windows}:#{?session_attached,(attached),}" 2>/dev/null || echo "")
    
    # Output grouped sessions with separators
    
    # Working sessions
    if [ ${#working_sessions[@]} -gt 0 ]; then
        echo -e "\033[1;33m━━━ ⚡ WORKING ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        printf '%s\n' "${working_sessions[@]}"
    fi
    
    # Done sessions
    if [ ${#done_sessions[@]} -gt 0 ]; then
        [ ${#working_sessions[@]} -gt 0 ] && echo
        echo -e "\033[1;32m━━━ ✓ DONE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        printf '%s\n' "${done_sessions[@]}"
    fi
    
    # No Claude sessions
    if [ ${#no_claude_sessions[@]} -gt 0 ]; then
        [ ${#working_sessions[@]} -gt 0 ] || [ ${#done_sessions[@]} -gt 0 ] && echo
        echo -e "\033[1;90m━━━ NO CLAUDE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        printf '%s\n' "${no_claude_sessions[@]}"
    fi
}

# Handle --no-fzf flag for daemon refresh
if [ "$1" = "--no-fzf" ]; then
    get_sessions_with_status
    exit 0
fi

# Main
sessions=$(get_sessions_with_status)

# Start smart monitor (will auto-stop when no SSH sessions)
MONITOR_SCRIPT="$(dirname "$0")/../smart-monitor.sh"
if [ -f "$MONITOR_SCRIPT" ]; then
    "$MONITOR_SCRIPT" start >/dev/null 2>&1
fi

# Add the reminder at the bottom of the session list
sessions_with_reminder=$(echo -e "$(get_sessions_with_status)\n\n\033[1;36m━━━ Hit Ctrl-R if something doesn't look right! ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m")

# Use fzf with manual refresh (Ctrl-R)
selected=$(echo "$sessions_with_reminder" | fzf \
    --ansi \
    --no-sort \
    --header="Sessions grouped by Claude status | j/k: navigate | Enter: select | Esc: cancel | Ctrl-R: refresh" \
    --preview 'if echo {} | grep -q "━━━"; then echo "Category separator"; else session=$(echo {} | awk "{print \$1}"); tmux capture-pane -ep -t "$session" 2>/dev/null || echo "No preview available"; fi' \
    --preview-window=right:40%:wrap \
    --prompt="Session> " \
    --bind="j:down,k:up,ctrl-j:preview-down,ctrl-k:preview-up" \
    --bind="ctrl-r:reload(bash '$0' --no-fzf)" \
    --layout=reverse \
    --info=inline)

# Switch to selected session (skip separator lines)
if [ -n "$selected" ] && ! echo "$selected" | grep -q "━━━"; then
    session_name=$(echo "$selected" | awk '{print $1}')
    tmux switch-client -t "$session_name"
fi