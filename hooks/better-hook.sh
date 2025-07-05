#!/usr/bin/env bash

# Claude Code hook for tmux status integration
# Updates tmux session status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-claude-status"
mkdir -p "$STATUS_DIR"

# Read JSON from stdin (required by Claude Code hooks)
JSON_INPUT=$(cat)

# Get tmux session if in tmux
if [ -n "$TMUX" ]; then
    # Try to get session name via tmux command first
    TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    
    # If that fails (e.g., when called from Claude hooks), parse TMUX env var
    if [ -z "$TMUX_SESSION" ]; then
        # TMUX format: /tmp/tmux-1000/default,3847,10
        # Extract session name from socket path
        SOCKET_PATH=$(echo "$TMUX" | cut -d',' -f1)
        TMUX_SESSION=$(basename "$SOCKET_PATH")
    fi
    
    if [ -n "$TMUX_SESSION" ]; then
        HOOK_TYPE="$1"
        STATUS_FILE="$STATUS_DIR/${TMUX_SESSION}.status"
        
        case "$HOOK_TYPE" in
            "PreToolUse"|"Notification")
                # Claude is starting to work
                echo "working" > "$STATUS_FILE"
                ;;
            "Stop"|"SubagentStop")
                # Claude has finished responding
                echo "done" > "$STATUS_FILE"
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0