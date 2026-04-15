#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/selection-targets.sh
source "$SCRIPT_DIR/lib/selection-targets.sh"

force_status_dir_refresh() {
    local tick_file="$STATUS_DIR/.wait-target-refresh.$$"
    : > "$tick_file"
    rm -f "$tick_file"
}

write_session_state() {
    local session="$1"
    local state="$2"

    if [ -f "$STATUS_DIR/${session}-remote.status" ]; then
        echo "$state" > "$STATUS_DIR/${session}-remote.status"
    else
        echo "$state" > "$STATUS_DIR/${session}.status"
    fi
}

selection_current_state() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token

    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            get_agent_status "$session"
            ;;
        window)
            get_window_status "$session" "${token#w}"
            ;;
        pane)
            get_pane_status "$session" "$token"
            ;;
    esac
}

cancel_wait() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token

    scope=$(selection_scope "$sel_name" "$sel_type")
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            rm -f "$WAIT_DIR/${session}.wait"
            rm -f "$WAIT_DIR/${session}_"*.wait 2>/dev/null
            write_session_state "$session" "done"

            local pane_file=""
            for pane_file in "$PANE_DIR/${session}_"*.status; do
                [ -f "$pane_file" ] || continue
                [ "$(cat "$pane_file" 2>/dev/null || echo "")" = "wait" ] && echo "done" > "$pane_file"
            done
            ;;
        window)
            local win_idx="${token#w}"
            local pane_id="" pane_status_file=""

            while IFS= read -r pane_id; do
                [ -n "$pane_id" ] || continue
                rm -f "$WAIT_DIR/${session}_${pane_id}.wait"
                pane_status_file="$PANE_DIR/${session}_${pane_id}.status"
                [ -f "$pane_status_file" ] && [ "$(cat "$pane_status_file" 2>/dev/null || echo "")" = "wait" ] && echo "done" > "$pane_status_file"
            done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_id}' 2>/dev/null)

            sync_session_after_child_scope_change "$session"
            ;;
        pane)
            rm -f "$WAIT_DIR/${session}_${token}.wait"
            if [ -f "$PANE_DIR/${session}_${token}.status" ] && [ "$(cat "$PANE_DIR/${session}_${token}.status" 2>/dev/null || echo "")" = "wait" ]; then
                echo "done" > "$PANE_DIR/${session}_${token}.status"
            fi

            sync_session_after_child_scope_change "$session"
            ;;
    esac

    force_status_dir_refresh
}

prompt_wait() {
    local sel_name="$1"
    local target_template="${sel_name//%/%%}"

    tmux command-prompt -p "Wait time in minutes:" \
        "run-shell '$SCRIPT_DIR/wait-session-handler.sh \"$target_template\" %1'"
}

main() {
    local sel_name="$1"
    local sel_type="$2"
    local state=""

    state=$(selection_current_state "$sel_name" "$sel_type" || true)
    if [ "$state" = "wait" ]; then
        cancel_wait "$sel_name" "$sel_type"
    else
        prompt_wait "$sel_name"
    fi
}

main "$1" "$2"
