#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows Claude status across all sessions

STATUS_DIR="$HOME/.cache/tmux-claude-status"
NOTIFICATION_SOUND="/usr/share/sounds/freedesktop/stereo/complete.oga"
LAST_STATUS_FILE="$STATUS_DIR/.last-status-summary"

# Count Claude sessions by status
count_claude_status() {
    local working=0
    local done=0
    local total_claude=0
    
    # Check all tmux sessions including SSH remote status
    while IFS= read -r session; do
        [ -z "$session" ] && continue
        
        # Check for SSH remote status file (e.g., reachgpu-remote.status)
        local remote_status_file="$STATUS_DIR/${session}-remote.status"
        local status_file="$STATUS_DIR/${session}.status"
        
        # Check if we have any status for this session
        if [ -f "$remote_status_file" ]; then
            # SSH session with remote status
            local status=$(cat "$remote_status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                ((total_claude++))
                case "$status" in
                    "working") ((working++)) ;;
                    "done") ((done++)) ;;
                    "wait") ((working++)) ;;  # Treat wait as working for status line
                esac
            fi
        elif [ -f "$status_file" ]; then
            # Local session status
            local status=$(cat "$status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                ((total_claude++))
                case "$status" in
                    "working") ((working++)) ;;
                    "done") ((done++)) ;;
                    "wait") ((working++)) ;;  # Treat wait as working for status line
                esac
            fi
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)
    
    echo "$working:$done:$total_claude"
}

# Play notification sound
play_notification() {
    if command -v paplay >/dev/null 2>&1 && [ -f "$NOTIFICATION_SOUND" ]; then
        paplay "$NOTIFICATION_SOUND" 2>/dev/null &
    elif command -v afplay >/dev/null 2>&1; then
        # macOS fallback
        afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
    elif command -v beep >/dev/null 2>&1; then
        # Terminal beep fallback
        beep 2>/dev/null &
    else
        # Last resort: terminal bell
        echo -ne '\a'
    fi
}

# Get current status
IFS=':' read -r working done total_claude <<< "$(count_claude_status)"

# Load previous status
prev_working=0
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_working=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "0")
fi

# Save current working count
echo "$working" > "$LAST_STATUS_FILE"

# Check if any Claude just finished (working count decreased)
if [ "$prev_working" -gt "$working" ] && [ "$prev_working" -gt 0 ]; then
    play_notification
fi

# Generate status line output
if [ "$total_claude" -eq 0 ]; then
    # No Claude sessions
    echo ""
elif [ "$working" -eq 0 ] && [ "$done" -gt 0 ]; then
    # All Claudes are done
    echo "#[fg=green,bold]✓ All Claudes ready#[default]"
elif [ "$working" -gt 0 ] && [ "$done" -gt 0 ]; then
    # Some working, some done
    echo "#[fg=yellow,bold]⚡ $working working#[default] #[fg=green]✓ $done done#[default]"
elif [ "$working" -gt 0 ]; then
    # All Claudes are working
    if [ "$working" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ Claude is working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $working Claudes are working#[default]"
    fi
fi