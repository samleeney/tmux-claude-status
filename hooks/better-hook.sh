#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux session status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
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
        PARKED_FILE="$STATUS_DIR/parked/${TMUX_SESSION}.parked"

        # Per-pane status tracking (for sidebar multi-agent display).
        PANE_DIR="$STATUS_DIR/panes"
        mkdir -p "$PANE_DIR"
        PANE_ID="${TMUX_PANE:-}"
        PANE_STATUS_FILE=""
        [ -n "$PANE_ID" ] && PANE_STATUS_FILE="$PANE_DIR/${TMUX_SESSION}_${PANE_ID}.status"

        case "$HOOK_TYPE" in
            "UserPromptSubmit"|"PreToolUse")
                # User submitted a prompt or Claude is calling a tool - cancel wait mode if active
                if [ -f "$WAIT_FILE" ]; then
                    rm -f "$WAIT_FILE"  # Remove wait timer
                fi
                if [ -f "$PARKED_FILE" ]; then
                    rm -f "$PARKED_FILE"
                fi
                # Clear unread marker on user interaction
                rm -f "$STATUS_DIR/${TMUX_SESSION}.unread" 2>/dev/null
                echo "working" > "$STATUS_FILE"
                [ -n "$PANE_STATUS_FILE" ] && echo "working" > "$PANE_STATUS_FILE"
                # Only write to remote status file if we're in an SSH session
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    rm -f "$STATUS_DIR/${TMUX_SESSION}-remote.unread" 2>/dev/null
                    echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                ;;
            "Stop"|"Notification")
                # Agent finished — mark done and check if session is unread
                PREV_STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "")
                echo "done" > "$STATUS_FILE"
                [ -n "$PANE_STATUS_FILE" ] && echo "done" > "$PANE_STATUS_FILE"
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    echo "done" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                # Mark unread if transitioning from working and session is not attached
                if [ "$PREV_STATUS" = "working" ]; then
                    IS_ATTACHED=$(tmux list-sessions -F "#{session_name}:#{?session_attached,1,}" 2>/dev/null | grep "^${TMUX_SESSION}:1$")
                    if [ -z "$IS_ATTACHED" ]; then
                        : > "$STATUS_DIR/${TMUX_SESSION}.unread"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            : > "$STATUS_DIR/${TMUX_SESSION}-remote.unread"
                        fi
                    fi
                fi

                # Play notification sound when Claude finishes
                SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0
