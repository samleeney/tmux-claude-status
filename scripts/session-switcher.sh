#!/usr/bin/env bash

# Exit on error
set -e

# Function to get Claude status for a session
get_claude_status() {
    local session_name="$1"
    local status_file="/tmp/tmux-claude-status/${session_name}.status"
    
    if [ -f "$status_file" ]; then
        cat "$status_file"
    else
        echo ""
    fi
}

# Function to format session line with Claude status
format_session() {
    local session_info="$1"
    local session_name=$(echo "$session_info" | cut -d: -f1)
    local windows=$(echo "$session_info" | cut -d: -f2)
    local attached=$(echo "$session_info" | cut -d: -f3)
    local claude_status=$(get_claude_status "$session_name")
    
    # Format output with status indicator
    if [ -n "$claude_status" ]; then
        printf "%-20s %2s windows %s [%s]\n" "$session_name" "$windows" "$attached" "$claude_status"
    else
        printf "%-20s %2s windows %s\n" "$session_name" "$windows" "$attached"
    fi
}

# Get all sessions
sessions=$(tmux list-sessions -F "#{session_name}:#{session_windows}:#{?session_attached,(attached),}")

# Format sessions with Claude status
formatted_sessions=""
while IFS= read -r session; do
    formatted_line=$(format_session "$session")
    formatted_sessions="${formatted_sessions}${formatted_line}\n"
done <<< "$sessions"

# Use fzf for selection with preview showing windows
selected=$(echo -e "$formatted_sessions" | fzf \
    --ansi \
    --header="Select session (Claude status: [working] or [done])" \
    --preview='tmux list-windows -t {1} -F "  #{window_index}: #{window_name} (#{window_panes} panes)"' \
    --preview-window=right:40% \
    --height=80% \
    --border \
    --prompt="Session: ")

# Extract session name and switch
if [ -n "$selected" ]; then
    session_name=$(echo "$selected" | awk '{print $1}')
    tmux switch-client -t "$session_name"
fi