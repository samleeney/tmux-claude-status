#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux session and pane status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
mkdir -p "$STATUS_DIR" "$PANE_DIR"

# Drain JSON from stdin (required by Claude Code hooks).
cat >/dev/null 2>&1 || true

in_remote_session() {
    [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
}

get_tmux_session() {
    local tmux_session=""

    if [ -n "${TMUX:-}" ] || in_remote_session; then
        tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)

        if [ -z "$tmux_session" ]; then
            if in_remote_session; then
                case "$(hostname -s 2>/dev/null)" in
                    instance-*) tmux_session="reachgpu" ;;
                    keen-schrodinger) tmux_session="sd1" ;;
                    sam-l4-workstation-image) tmux_session="l4-workstation" ;;
                    persistent-faraday) tmux_session="tig" ;;
                    instance-20250620-122051) tmux_session="reachgpu" ;;
                    *) tmux_session=$(hostname -s 2>/dev/null) ;;
                esac
            elif [ -n "${TMUX:-}" ]; then
                local socket_path="${TMUX%%,*}"
                tmux_session=$(basename "$socket_path")
            fi
        fi
    fi

    [ -n "$tmux_session" ] || return 1
    printf '%s\n' "$tmux_session"
}

set_status() {
    local tmux_session="$1"
    local requested_status="$2"
    local session_status="$requested_status"
    local status_file="$STATUS_DIR/${tmux_session}.status"
    local remote_status_file="$STATUS_DIR/${tmux_session}-remote.status"

    if [ -n "${TMUX_PANE:-}" ]; then
        local pane_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.status"
        local agent_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.agent"
        echo "$requested_status" > "$pane_file"
        echo "claude" > "$agent_file"

        session_status="done"
        local existing_pane_file=""
        for existing_pane_file in "$PANE_DIR/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue

            local pane_status=""
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            case "$pane_status" in
                working)
                    session_status="working"
                    break
                    ;;
                wait)
                    if [ "$session_status" != "working" ]; then
                        session_status="wait"
                    fi
                    ;;
            esac
        done
    fi

    echo "$session_status" > "$status_file"
    if in_remote_session; then
        echo "$session_status" > "$remote_status_file" 2>/dev/null
    fi
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"
WAIT_FILE="$STATUS_DIR/wait/${TMUX_SESSION}.wait"
PARKED_FILE="$STATUS_DIR/parked/${TMUX_SESSION}.parked"

case "$HOOK_TYPE" in
    UserPromptSubmit)
        # User submitted a prompt — this is an explicit interaction, so
        # cancel wait mode and unpark.
        rm -f "$WAIT_FILE" "$PARKED_FILE"
        set_status "$TMUX_SESSION" "working"
        ;;
    PreToolUse)
        # Agent is calling a tool — mark working but do NOT unpark.
        # Parking is an explicit user decision; only user interaction
        # (UserPromptSubmit) should unpark.
        rm -f "$WAIT_FILE"
        if [ ! -f "$PARKED_FILE" ]; then
            set_status "$TMUX_SESSION" "working"
        fi
        ;;
    Stop)
        # Claude has finished responding (SubagentStop excluded - subagents
        # finishing doesn't mean the main agent is done).
        set_status "$TMUX_SESSION" "done"
        ;;
    Notification)
        # Claude is waiting for user input.
        set_status "$TMUX_SESSION" "done"

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
        ;;
esac

# Always exit successfully
exit 0
