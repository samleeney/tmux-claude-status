#!/usr/bin/env bash

# Claude Code hook for tmux status integration
# Updates tmux session status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-claude-status"
mkdir -p "$STATUS_DIR"

# Read JSON from stdin (required by Claude Code hooks)
JSON_INPUT=$(cat)

# Get tmux session if in tmux OR if we're in an SSH session
if [ -n "$TMUX" ] || [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    # Try to get session name via tmux command first
    TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    
    # If that fails (e.g., when called from Claude hooks or over SSH)
    if [ -z "$TMUX_SESSION" ]; then
        # For SSH sessions, try to auto-detect session name from the SSH connection
        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
            # Use a simple heuristic: assume session name matches common SSH aliases
            # Check if we're on known servers and map to likely session names
            case $(hostname -s) in
                instance-*) TMUX_SESSION="reachgpu" ;;  # Your GPU server
                keen-schrodinger) TMUX_SESSION="sd1" ;;
                sam-l4-workstation-image) TMUX_SESSION="l4-workstation" ;;
                persistent-faraday) TMUX_SESSION="tig" ;;
                instance-20250620-122051) TMUX_SESSION="reachgpu" ;;
                *) TMUX_SESSION=$(hostname -s) ;;       # Default to hostname
            esac
        else
            # TMUX format: /tmp/tmux-1000/default,3847,10
            # Extract session name from socket path
            SOCKET_PATH=$(echo "$TMUX" | cut -d',' -f1)
            TMUX_SESSION=$(basename "$SOCKET_PATH")
        fi
    fi
    
    if [ -n "$TMUX_SESSION" ]; then
        HOOK_TYPE="$1"
        STATUS_FILE="$STATUS_DIR/${TMUX_SESSION}.status"
        REMOTE_STATUS_FILE="$STATUS_DIR/${TMUX_SESSION}-remote.status"
        WAIT_FILE="$STATUS_DIR/wait/${TMUX_SESSION}.wait"
        
        case "$HOOK_TYPE" in
            "PreToolUse")
                # Claude is starting to work - cancel wait mode if active
                if [ -f "$WAIT_FILE" ]; then
                    rm -f "$WAIT_FILE"  # Remove wait timer
                fi
                echo "working" > "$STATUS_FILE"
                # Only write to remote status file if we're in an SSH session
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                ;;
            "Stop"|"SubagentStop")
                # Claude has finished responding
                echo "done" > "$STATUS_FILE"
                # Only write to remote status file if we're in an SSH session
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    echo "done" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                
                # Play notification sound when Claude finishes
                notification_sound="/usr/share/sounds/freedesktop/stereo/complete.oga"
                if command -v paplay >/dev/null 2>&1 && [ -f "$notification_sound" ]; then
                    paplay "$notification_sound" 2>/dev/null &
                elif command -v afplay >/dev/null 2>&1; then
                    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
                elif command -v beep >/dev/null 2>&1; then
                    beep 2>/dev/null &
                else
                    echo -ne '\a'
                fi
                ;;
            "Notification")
                # Claude is waiting for user input
                echo "done" > "$STATUS_FILE"
                # Only write to remote status file if we're in an SSH session
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    echo "done" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0