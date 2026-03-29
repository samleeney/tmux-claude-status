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

        case "$HOOK_TYPE" in
            "UserPromptSubmit")
                # User submitted a prompt — explicit interaction, unpark and cancel wait
                if [ -f "$WAIT_FILE" ]; then
                    rm -f "$WAIT_FILE"
                fi
                if [ -f "$PARKED_FILE" ]; then
                    rm -f "$PARKED_FILE"
                fi
                echo "working" > "$STATUS_FILE"
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                ;;
            "PreToolUse")
                # Agent is calling a tool — check if it's asking the user a question
                TOOL_NAME=$(echo "$JSON_INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"//')
                if [ -f "$WAIT_FILE" ]; then
                    rm -f "$WAIT_FILE"
                fi
                if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                    # Agent needs user input — distinct from "done" (agent stopped)
                    if [ ! -f "$PARKED_FILE" ]; then
                        echo "ask" > "$STATUS_FILE"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            echo "ask" > "$REMOTE_STATUS_FILE" 2>/dev/null
                        fi
                        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                        "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
                    fi
                else
                    # Normal tool use — mark working but don't unpark
                    if [ ! -f "$PARKED_FILE" ]; then
                        echo "working" > "$STATUS_FILE"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                        fi
                    fi
                fi
                ;;
            "Stop")
                # Claude has finished responding (SubagentStop excluded - subagents finishing doesn't mean the main agent is done)
                echo "done" > "$STATUS_FILE"
                # Only write to remote status file if we're in an SSH session
                if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                    echo "done" > "$REMOTE_STATUS_FILE" 2>/dev/null
                fi
                ;;
            "Notification")
                # Claude is waiting for user input — don't overwrite "ask" status
                CURRENT_STATUS=$(cat "$STATUS_FILE" 2>/dev/null)
                if [ "$CURRENT_STATUS" != "ask" ]; then
                    echo "done" > "$STATUS_FILE"
                    if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                        echo "done" > "$REMOTE_STATUS_FILE" 2>/dev/null
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
