#!/usr/bin/env bash

# Park the current session so it stays in the switcher but drops out of the toolbar.

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
mkdir -p "$PARKED_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

current_session=$(tmux display-message -p "#{session_name}")

has_agent_in_session() {
    session_has_agent_process "$1"
}

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

if ! has_agent_in_session "$current_session" && ! is_ssh_session "$current_session"; then
    if [ ! -f "$STATUS_DIR/${current_session}.status" ] && [ ! -f "$STATUS_DIR/${current_session}-remote.status" ]; then
        tmux display-message "Session $current_session has no agent state to park"
        exit 1
    fi
fi

rm -f "$WAIT_DIR/$current_session.wait"
: > "$PARKED_DIR/$current_session.parked"

if is_ssh_session "$current_session"; then
    echo "parked" > "$STATUS_DIR/${current_session}-remote.status"
else
    echo "parked" > "$STATUS_DIR/${current_session}.status"
fi

NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"
if [ -f "$NEXT_DONE_SCRIPT" ]; then
    if ! bash "$NEXT_DONE_SCRIPT" "$current_session" 2>/dev/null; then
        tmux display-message "Session $current_session parked for later"
    fi
else
    tmux display-message "Session $current_session parked for later"
fi
