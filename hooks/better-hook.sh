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
        WAIT_DIR="$STATUS_DIR/wait"
        PARKED_DIR="$STATUS_DIR/parked"
        mkdir -p "$WAIT_DIR" "$PARKED_DIR"
        WAIT_FILE="$WAIT_DIR/${TMUX_SESSION}.wait"
        PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}.parked"

        # Per-pane status tracking (for sidebar multi-agent display).
        PANE_DIR="$STATUS_DIR/panes"
        mkdir -p "$PANE_DIR"
        PANE_ID="${TMUX_PANE:-}"
        PANE_STATUS_FILE=""
        [ -n "$PANE_ID" ] && PANE_STATUS_FILE="$PANE_DIR/${TMUX_SESSION}_${PANE_ID}.status"

        case "$HOOK_TYPE" in
            "UserPromptSubmit")
                # User submitted a prompt - explicit interaction, unpark and cancel wait.
                if [ -f "$WAIT_FILE" ]; then
                    rm -f "$WAIT_FILE"
                fi
                if [ -f "$PARKED_FILE" ]; then rm -f "$PARKED_FILE"
                fi
                rm -f "$STATUS_DIR/${TMUX_SESSION}.unread" 2>/dev/null
                echo "working" > "$STATUS_FILE"
                [ -n "$PANE_STATUS_FILE" ] && echo "working" > "$PANE_STATUS_FILE"
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    rm -f "$STATUS_DIR/${TMUX_SESSION}-remote.unread" 2>/dev/null
                    echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                ;;
            "PreToolUse")
                # Detect AskUserQuestion; respect explicit wait/park overrides.
                TOOL_NAME=$(echo "$JSON_INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"//')
                if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                    # Agent needs user input — distinct from "done" (agent stopped)
                    if [ ! -f "$PARKED_FILE" ] && [ ! -f "$WAIT_FILE" ]; then
                        echo "ask" > "$STATUS_FILE"
                        [ -n "$PANE_STATUS_FILE" ] && echo "ask" > "$PANE_STATUS_FILE"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            echo "ask" > "$REMOTE_STATUS_FILE" 2>/dev/null
                        fi
                        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                        "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
                    fi
                else
                    # Normal tool use — mark working but don't unpark
                    if [ -f "$PARKED_FILE" ] || [ -f "$WAIT_FILE" ]; then
                        :
                    else
                        echo "working" > "$STATUS_FILE"
                        [ -n "$PANE_STATUS_FILE" ] && echo "working" > "$PANE_STATUS_FILE"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                        fi
                    fi
                fi
                ;;
            "Stop"|"Notification")
                # Keep Notification from overwriting "ask"; mark unread if unattended.
                PREV_STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "")
                if [ "$HOOK_TYPE" = "Notification" ] && [ "$PREV_STATUS" = "ask" ]; then
                    :
                else
                    echo "done" > "$STATUS_FILE"
                    [ -n "$PANE_STATUS_FILE" ] && echo "done" > "$PANE_STATUS_FILE"
                    if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                        echo "done" > "$REMOTE_STATUS_FILE" 2>/dev/null
                    fi
                    if [ "$PREV_STATUS" = "working" ]; then
                        IS_ATTACHED=$(tmux list-sessions -F "#{session_name}:#{?session_attached,1,}" 2>/dev/null | grep -Fx "${TMUX_SESSION}:1" || true)
                        if [ -z "$IS_ATTACHED" ]; then
                            : > "$STATUS_DIR/${TMUX_SESSION}.unread"
                            if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                                : > "$STATUS_DIR/${TMUX_SESSION}-remote.unread"
                            fi
                        fi
                    fi

                    # Play notification sound when Claude finishes a turn.
                    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                    "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
                fi
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0
