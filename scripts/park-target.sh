#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/selection-targets.sh
source "$SCRIPT_DIR/lib/selection-targets.sh"

force_status_dir_refresh() {
    local tick_file="$STATUS_DIR/.park-target-refresh.$$"
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

toggle_park() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token state

    scope=$(selection_scope "$sel_name" "$sel_type")
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")
    state=$(selection_current_state "$sel_name" "$sel_type" || true)

    mkdir -p "$PARKED_DIR" "$PANE_DIR"

    case "$scope" in
        session)
            if [ "$state" = "parked" ]; then
                rm -f "$PARKED_DIR/${session}.parked"
                rm -f "$PARKED_DIR/${session}_"*.parked 2>/dev/null
                write_session_state "$session" "done"

                local pane_file=""
                for pane_file in "$PANE_DIR/${session}_"*.status; do
                    [ -f "$pane_file" ] || continue
                    [ "$(cat "$pane_file" 2>/dev/null || echo "")" = "parked" ] && echo "done" > "$pane_file"
                done
            else
                rm -f "$WAIT_DIR/${session}.wait"
                : > "$PARKED_DIR/${session}.parked"
                write_session_state "$session" "parked"

                local pane_id=""
                while IFS= read -r pane_id; do
                    [ -n "$pane_id" ] || continue
                    : > "$PARKED_DIR/${session}_${pane_id}.parked"
                    echo "parked" > "$PANE_DIR/${session}_${pane_id}.status"
                    rm -f "$WAIT_DIR/${session}_${pane_id}.wait" 2>/dev/null
                done < <(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)
            fi
            ;;
        window)
            local win_idx="${token#w}"
            local pane_id="" pane_status_file=""

            if [ "$state" = "parked" ]; then
                while IFS= read -r pane_id; do
                    [ -n "$pane_id" ] || continue
                    rm -f "$PARKED_DIR/${session}_${pane_id}.parked"
                    pane_status_file="$PANE_DIR/${session}_${pane_id}.status"
                    [ -f "$pane_status_file" ] && [ "$(cat "$pane_status_file" 2>/dev/null || echo "")" = "parked" ] && echo "done" > "$pane_status_file"
                done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_id}' 2>/dev/null)

                rm -f "$PARKED_DIR/${session}.parked"
                [ "$(get_agent_status "$session")" = "parked" ] && write_session_state "$session" "done"
            else
                while IFS= read -r pane_id; do
                    [ -n "$pane_id" ] || continue
                    : > "$PARKED_DIR/${session}_${pane_id}.parked"
                    echo "parked" > "$PANE_DIR/${session}_${pane_id}.status"
                    rm -f "$WAIT_DIR/${session}_${pane_id}.wait" 2>/dev/null
                done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_id}' 2>/dev/null)
            fi
            ;;
        pane)
            if [ "$state" = "parked" ]; then
                rm -f "$PARKED_DIR/${session}_${token}.parked"
                if [ -f "$PANE_DIR/${session}_${token}.status" ]; then
                    echo "done" > "$PANE_DIR/${session}_${token}.status"
                fi

                rm -f "$PARKED_DIR/${session}.parked"
                [ "$(get_agent_status "$session")" = "parked" ] && write_session_state "$session" "done"
            else
                rm -f "$WAIT_DIR/${session}_${token}.wait" 2>/dev/null
                : > "$PARKED_DIR/${session}_${token}.parked"
                echo "parked" > "$PANE_DIR/${session}_${token}.status"
            fi
            ;;
    esac

    force_status_dir_refresh
}

toggle_park "$1" "$2"
