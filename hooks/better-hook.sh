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
        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
            case $(hostname -s) in
                instance-*) TMUX_SESSION="reachgpu" ;;
                keen-schrodinger) TMUX_SESSION="sd1" ;;
                sam-l4-workstation-image) TMUX_SESSION="l4-workstation" ;;
                persistent-faraday) TMUX_SESSION="tig" ;;
                instance-20250620-122051) TMUX_SESSION="reachgpu" ;;
                *) TMUX_SESSION=$(hostname -s) ;;
            esac
        else
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
        SESSION_PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}.parked"

        # Per-pane status tracking
        PANE_DIR="$STATUS_DIR/panes"
        mkdir -p "$PANE_DIR"
        PANE_ID="${TMUX_PANE:-}"
        PANE_STATUS_FILE=""
        PANE_PARKED_FILE=""
        PANE_WAIT_FILE=""
        if [ -n "$PANE_ID" ]; then
            PANE_STATUS_FILE="$PANE_DIR/${TMUX_SESSION}_${PANE_ID}.status"
            PANE_PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}_${PANE_ID}.parked"
            PANE_WAIT_FILE="$WAIT_DIR/${TMUX_SESSION}_${PANE_ID}.wait"
        fi

        # Check if the current pane is parked (either session-level or pane-level).
        _pane_is_parked() {
            [ -f "$SESSION_PARKED_FILE" ] && return 0
            [ -n "$PANE_PARKED_FILE" ] && [ -f "$PANE_PARKED_FILE" ] && return 0
            return 1
        }

        # Check if the current pane is waited (either session-level or pane-level).
        _pane_is_waited() {
            [ -f "$WAIT_FILE" ] && return 0
            [ -n "$PANE_WAIT_FILE" ] && [ -f "$PANE_WAIT_FILE" ] && return 0
            return 1
        }

        # Hierarchical unpark for the current pane:
        #   Session parked → unpark entire session (all panes)
        #   Window parked (all panes in window parked) → unpark all panes in window
        #   Pane parked → unpark just this pane
        _unpark_current() {
            if [ -f "$SESSION_PARKED_FILE" ]; then
                # Session-level park: unpark everything
                rm -f "$SESSION_PARKED_FILE"
                rm -f "$PARKED_DIR/${TMUX_SESSION}_"*.parked 2>/dev/null
                # Reset all pane statuses from "parked" to "done"
                for pf in "$PANE_DIR/${TMUX_SESSION}_"*.status; do
                    [ -f "$pf" ] && [ "$(cat "$pf")" = "parked" ] && echo "done" > "$pf"
                done
            elif [ -n "$PANE_PARKED_FILE" ] && [ -f "$PANE_PARKED_FILE" ]; then
                # Check if all panes in current window are parked (window-level park)
                local cur_window
                cur_window=$(tmux display-message -p '#{window_index}' 2>/dev/null)
                local all_parked=1
                while IFS= read -r wp_id; do
                    [ -z "$wp_id" ] && continue
                    if [ ! -f "$PARKED_DIR/${TMUX_SESSION}_${wp_id}.parked" ]; then
                        all_parked=0
                        break
                    fi
                done < <(tmux list-panes -t "${TMUX_SESSION}:${cur_window}" -F '#{pane_id}' 2>/dev/null)

                if [ "$all_parked" -eq 1 ] && [ -n "$cur_window" ]; then
                    # Window-level: unpark all panes in this window
                    while IFS= read -r wp_id; do
                        [ -z "$wp_id" ] && continue
                        rm -f "$PARKED_DIR/${TMUX_SESSION}_${wp_id}.parked"
                        local wpf="$PANE_DIR/${TMUX_SESSION}_${wp_id}.status"
                        [ -f "$wpf" ] && [ "$(cat "$wpf")" = "parked" ] && echo "done" > "$wpf"
                    done < <(tmux list-panes -t "${TMUX_SESSION}:${cur_window}" -F '#{pane_id}' 2>/dev/null)
                else
                    # Pane-level: unpark just this pane
                    rm -f "$PANE_PARKED_FILE"
                fi
                # Reset pane status from "parked"
                [ -n "$PANE_STATUS_FILE" ] && [ -f "$PANE_STATUS_FILE" ] && [ "$(cat "$PANE_STATUS_FILE")" = "parked" ] && echo "done" > "$PANE_STATUS_FILE"
            fi
        }

        # Hierarchical unwait — mirrors _unpark_current logic.
        _unwait_current() {
            if [ -f "$WAIT_FILE" ]; then
                # Session-level wait: cancel everything
                rm -f "$WAIT_FILE"
                rm -f "$WAIT_DIR/${TMUX_SESSION}_"*.wait 2>/dev/null
                for pf in "$PANE_DIR/${TMUX_SESSION}_"*.status; do
                    [ -f "$pf" ] && [ "$(cat "$pf")" = "wait" ] && echo "done" > "$pf"
                done
            elif [ -n "$PANE_WAIT_FILE" ] && [ -f "$PANE_WAIT_FILE" ]; then
                local cur_window
                cur_window=$(tmux display-message -p '#{window_index}' 2>/dev/null)
                local all_waiting=1
                while IFS= read -r wp_id; do
                    [ -z "$wp_id" ] && continue
                    if [ ! -f "$WAIT_DIR/${TMUX_SESSION}_${wp_id}.wait" ]; then
                        all_waiting=0
                        break
                    fi
                done < <(tmux list-panes -t "${TMUX_SESSION}:${cur_window}" -F '#{pane_id}' 2>/dev/null)

                if [ "$all_waiting" -eq 1 ] && [ -n "$cur_window" ]; then
                    # Window-level: cancel all pane waits in this window
                    while IFS= read -r wp_id; do
                        [ -z "$wp_id" ] && continue
                        rm -f "$WAIT_DIR/${TMUX_SESSION}_${wp_id}.wait"
                        local wpf="$PANE_DIR/${TMUX_SESSION}_${wp_id}.status"
                        [ -f "$wpf" ] && [ "$(cat "$wpf")" = "wait" ] && echo "done" > "$wpf"
                    done < <(tmux list-panes -t "${TMUX_SESSION}:${cur_window}" -F '#{pane_id}' 2>/dev/null)
                else
                    # Pane-level: cancel just this pane's wait
                    rm -f "$PANE_WAIT_FILE"
                fi
                [ -n "$PANE_STATUS_FILE" ] && [ -f "$PANE_STATUS_FILE" ] && [ "$(cat "$PANE_STATUS_FILE")" = "wait" ] && echo "done" > "$PANE_STATUS_FILE"
            fi
        }

        case "$HOOK_TYPE" in
            "UserPromptSubmit")
                # User submitted a prompt — explicit interaction, unpark and cancel wait.
                _unpark_current
                _unwait_current
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
                    if ! _pane_is_parked && ! _pane_is_waited; then
                        echo "ask" > "$STATUS_FILE"
                        [ -n "$PANE_STATUS_FILE" ] && echo "ask" > "$PANE_STATUS_FILE"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            echo "ask" > "$REMOTE_STATUS_FILE" 2>/dev/null
                        fi
                        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                        "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
                    fi
                else
                    # Normal tool use — mark working but don't touch parked/waited panes
                    if ! _pane_is_parked && ! _pane_is_waited; then
                        echo "working" > "$STATUS_FILE"
                        [ -n "$PANE_STATUS_FILE" ] && echo "working" > "$PANE_STATUS_FILE"
                        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                            echo "working" > "$REMOTE_STATUS_FILE" 2>/dev/null
                        fi
                    fi
                fi
                ;;
            "Stop"|"Notification")
                # Don't overwrite parked or waited panes. Keep Notification from overwriting "ask".
                if _pane_is_parked || _pane_is_waited; then
                    :
                else
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

                        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                        "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
                    fi
                fi
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0
