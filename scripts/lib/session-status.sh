#!/usr/bin/env bash

# Shared session-status helpers used by the sidebar, switcher, and other scripts.
# Provides: is_ssh_session, has_agent_in_session, normalize_local_wait_status,
#           get_agent_status, plus STATUS_DIR / PARKED_DIR / WAIT_DIR constants.

[[ -n "${_SESSION_STATUS_LOADED:-}" ]] && return 0
_SESSION_STATUS_LOADED=1

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
WAIT_DIR="$STATUS_DIR/wait"
PANE_DIR="$STATUS_DIR/panes"
mkdir -p "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR" "$PANE_DIR"

# Source process-detection helpers from the same lib directory.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-processes.sh
source "$_LIB_DIR/agent-processes.sh"

is_ssh_session() {
    local session="$1"
    if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
        return 0
    fi
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}

has_agent_in_session() {
    session_has_agent_process "$1"
}

normalize_local_wait_status() {
    local session="$1"
    local status_file="$STATUS_DIR/${session}.status"
    local wait_file="$WAIT_DIR/${session}.wait"

    [ ! -f "$status_file" ] && return

    local status
    status=$(cat "$status_file" 2>/dev/null || echo "")
    if [ "$status" = "wait" ] && [ ! -f "$wait_file" ]; then
        echo "done" > "$status_file" 2>/dev/null
    fi
}

get_agent_status() {
    local session="$1"

    if [ -f "$PARKED_DIR/${session}.parked" ]; then
        echo "parked"
        return
    fi

    # Check for remote status file first (for SSH sessions)
    local remote_status="$STATUS_DIR/${session}-remote.status"
    if [ -f "$remote_status" ] && is_ssh_session "$session"; then
        cat "$remote_status" 2>/dev/null
        return
    elif [ -f "$remote_status" ] && ! is_ssh_session "$session"; then
        rm -f "$remote_status" 2>/dev/null
    fi

    # Check local status files
    local status_file="$STATUS_DIR/${session}.status"
    if [ -f "$status_file" ]; then
        normalize_local_wait_status "$session"
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

get_ssh_host() {
    local session="$1"
    if is_ssh_session "$session"; then
        echo "$session"
    fi
}
