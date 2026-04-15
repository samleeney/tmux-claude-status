#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/selection-targets.sh
source "$SCRIPT_DIR/lib/selection-targets.sh"

force_status_dir_refresh() {
    local tick_file="$STATUS_DIR/.close-target-refresh.$$"
    : > "$tick_file"
    rm -f "$tick_file"
}

cleanup_pane_state() {
    local session="$1"
    local pane_id="$2"

    rm -f "$PANE_DIR/${session}_${pane_id}.status"
    rm -f "$PANE_DIR/${session}_${pane_id}.agent"
    rm -f "$WAIT_DIR/${session}_${pane_id}.wait"
    rm -f "$PARKED_DIR/${session}_${pane_id}.parked"
}

cleanup_session_state() {
    local session="$1"

    rm -f "$STATUS_DIR/${session}.status"
    rm -f "$STATUS_DIR/${session}-remote.status"
    rm -f "$STATUS_DIR/${session}.unread"
    rm -f "$STATUS_DIR/${session}-remote.unread"
    rm -f "$WAIT_DIR/${session}.wait" "$WAIT_DIR/${session}_"*.wait
    rm -f "$PARKED_DIR/${session}.parked" "$PARKED_DIR/${session}_"*.parked
    rm -f "$PANE_DIR/${session}_"*.status "$PANE_DIR/${session}_"*.agent
}

refresh_session_tracking() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        cleanup_session_state "$session"
        return
    fi

    local status_file="$STATUS_DIR/${session}.status"
    local remote_status_file="$STATUS_DIR/${session}-remote.status"
    local best_status=""
    local best_priority=0
    local pane_file=""

    if [ -f "$PARKED_DIR/${session}.parked" ]; then
        echo "parked" > "$status_file"
        [ -f "$remote_status_file" ] && echo "parked" > "$remote_status_file"
        return 0
    fi

    if [ -f "$WAIT_DIR/${session}.wait" ]; then
        local now expiry
        printf -v now '%(%s)T' -1
        expiry=$(cat "$WAIT_DIR/${session}.wait" 2>/dev/null || echo "")
        if [ -n "$expiry" ] && [ "$expiry" -gt "$now" ] 2>/dev/null; then
            echo "wait" > "$status_file"
            [ -f "$remote_status_file" ] && echo "wait" > "$remote_status_file"
            return 0
        fi
        rm -f "$WAIT_DIR/${session}.wait"
    fi

    for pane_file in "$PANE_DIR/${session}_"*.status; do
        [ -f "$pane_file" ] || continue

        local pane_status pane_priority
        pane_status=$(cat "$pane_file" 2>/dev/null || echo "")
        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done

    if [ -n "$best_status" ]; then
        echo "$best_status" > "$status_file"
        [ -f "$remote_status_file" ] && echo "$best_status" > "$remote_status_file"
    else
        rm -f "$status_file" "$remote_status_file"
    fi

    return 0
}

find_fallback_pane() {
    local sel_name="$1"
    local sel_type="$2"
    local exclude=()
    local pane_id=""

    while IFS= read -r pane_id; do
        [ -n "$pane_id" ] && exclude+=("$pane_id")
    done < <(selection_list_panes "$sel_name" "$sel_type")

    local line=""
    while IFS=$'\t' read -r session window_index pane pane_title; do
        [ -z "$pane" ] && continue
        [ "$pane_title" = "agent-sidebar" ] && continue

        local blocked=0 item=""
        for item in "${exclude[@]}"; do
            if [ "$pane" = "$item" ]; then
                blocked=1
                break
            fi
        done
        [ "$blocked" -eq 1 ] && continue

        printf '%s\t%s\t%s\n' "$session" "$window_index" "$pane"
        return 0
    done < <(tmux list-panes -a -F "#{session_name}	#{window_index}	#{pane_id}	#{pane_title}" 2>/dev/null)

    return 1
}

switch_client_to_fallback() {
    local sel_name="$1"
    local sel_type="$2"

    selection_includes_current_client "$sel_name" "$sel_type" || return 0

    local fallback session window_index pane
    fallback=$(find_fallback_pane "$sel_name" "$sel_type" || true)
    [ -z "$fallback" ] && return 0

    IFS=$'\t' read -r session window_index pane <<< "$fallback"
    tmux switch-client -t "$session" 2>/dev/null || true
    tmux select-window -t "${session}:${window_index}" 2>/dev/null || true
    tmux select-pane -t "$pane" 2>/dev/null || true
}

switch_client_to_next_inbox_or_fallback() {
    local sel_name="$1"
    local sel_type="$2"

    selection_includes_current_client "$sel_name" "$sel_type" || return 0

    if bash "$SCRIPT_DIR/next-done-project.sh" --exclude "$sel_name" "$sel_type" >/dev/null 2>&1; then
        return 0
    fi

    switch_client_to_fallback "$sel_name" "$sel_type"
}

apply_close() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    local pane_ids=()
    local pane_id=""

    scope=$(selection_scope "$sel_name" "$sel_type")
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    while IFS= read -r pane_id; do
        [ -n "$pane_id" ] && pane_ids+=("$pane_id")
    done < <(selection_list_panes "$sel_name" "$sel_type")

    case "$scope" in
        pane)
            switch_client_to_fallback "$sel_name" "$sel_type"
            cleanup_pane_state "$session" "$token"
            tmux kill-pane -t "$token" 2>/dev/null || true
            refresh_session_tracking "$session"
            ;;
        window)
            switch_client_to_fallback "$sel_name" "$sel_type"
            local item=""
            for item in "${pane_ids[@]}"; do
                cleanup_pane_state "$session" "$item"
            done
            tmux kill-window -t "${session}:${token#w}" 2>/dev/null || true
            refresh_session_tracking "$session"
            ;;
        session)
            switch_client_to_next_inbox_or_fallback "$sel_name" "$sel_type"
            cleanup_session_state "$session"
            tmux kill-session -t "$session" 2>/dev/null || true
            ;;
        *)
            return 1
            ;;
    esac

    force_status_dir_refresh
}

describe_selection() {
    local sel_name="$1"
    local sel_type="$2"
    local scope prompt confirm

    scope=$(selection_scope "$sel_name" "$sel_type")
    prompt=$(selection_close_prompt "$sel_name" "$sel_type")
    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        confirm="yes"
    else
        confirm="no"
    fi

    printf '%s\t%s\t%s\n' "$scope" "$confirm" "$prompt"
}

case "${1:-}" in
    --describe)
        describe_selection "$2" "$3"
        ;;
    *)
        apply_close "$1" "$2"
        ;;
esac
