#!/usr/bin/env bash

# Shared session-status helpers used by the sidebar, switcher, and other scripts.
# Provides: is_ssh_session, has_agent_in_session, session_is_fully_parked,
#           normalize_local_wait_status, status_priority, get_pane_status,
#           get_window_status, get_agent_status, sync_session_after_child_scope_change,
#           plus STATUS_DIR / PARKED_DIR / WAIT_DIR constants.

[[ -n "${_SESSION_STATUS_LOADED:-}" ]] && return 0
_SESSION_STATUS_LOADED=1

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
WAIT_DIR="$STATUS_DIR/wait"
PANE_DIR="$STATUS_DIR/panes"
SIDEBAR_CLIENT_DIR="$STATUS_DIR/sidebar-clients"
STATUS_LINE_CACHE_FILE="$STATUS_DIR/.status-line"
STATUS_LINE_COUNTS_FILE="$STATUS_DIR/.status-line-counts"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
mkdir -p "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR" "$PANE_DIR" "$SIDEBAR_CLIENT_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

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

session_is_fully_parked() {
    local session="$1"
    local live_pane=1
    local pane_session=""
    local pane_id=""

    while IFS=$'\t' read -r pane_session pane_id; do
        [ "$pane_session" = "$session" ] || continue
        [ -n "$pane_id" ] || continue
        live_pane=0
        [ -f "$PARKED_DIR/${session}_${pane_id}.parked" ] || return 1
    done < <(tmux list-panes -a -F '#{session_name}'$'\t''#{pane_id}' 2>/dev/null)

    if [ "$live_pane" -eq 0 ]; then
        return 0
    fi

    local seen_pane=1
    local pane_file=""

    for pane_file in "$PANE_DIR/${session}_"*.status; do
        [ -f "$pane_file" ] || continue
        seen_pane=0

        local pane_id
        pane_id=$(basename "$pane_file" .status)
        pane_id="${pane_id#${session}_}"
        [ -f "$PARKED_DIR/${session}_${pane_id}.parked" ] || return 1
    done

    if [ "$seen_pane" -eq 0 ]; then
        return 0
    fi

    [ -f "$PARKED_DIR/${session}.parked" ]
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

status_priority() {
    case "$1" in
        working) echo 5 ;;
        wait) echo 4 ;;
        ask) echo 3 ;;
        done) echo 2 ;;
        parked) echo 1 ;;
        *) echo 0 ;;
    esac
}

write_session_status() {
    local session="$1"
    local state="$2"
    local remote_status="$STATUS_DIR/${session}-remote.status"

    if [ -f "$remote_status" ] && is_ssh_session "$session"; then
        echo "$state" > "$remote_status" 2>/dev/null
    else
        [ -f "$remote_status" ] && ! is_ssh_session "$session" && rm -f "$remote_status" 2>/dev/null
        echo "$state" > "$STATUS_DIR/${session}.status" 2>/dev/null
    fi
}

recompute_session_status() {
    local session="$1"
    local best_status="done"
    local best_priority
    best_priority=$(status_priority "$best_status")

    if session_is_fully_parked "$session"; then
        write_session_status "$session" "parked"
        return
    fi

    if [ -f "$WAIT_DIR/${session}.wait" ]; then
        write_session_status "$session" "wait"
        return
    fi

    local pane_file=""
    for pane_file in "$PANE_DIR/${session}_"*.status; do
        [ -f "$pane_file" ] || continue

        local pane_name pane_id pane_status pane_priority
        pane_name=$(basename "$pane_file" .status)
        pane_id="${pane_name##*_}"

        if [ -f "$PARKED_DIR/${session}_${pane_id}.parked" ]; then
            pane_status="parked"
        elif [ -f "$WAIT_DIR/${session}_${pane_id}.wait" ]; then
            pane_status="wait"
        else
            pane_status=$(cat "$pane_file" 2>/dev/null || echo "")
            if [ "$pane_status" = "wait" ]; then
                pane_status="done"
                echo "done" > "$pane_file" 2>/dev/null
            fi
        fi

        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done

    write_session_status "$session" "$best_status"
}

sync_session_after_child_scope_change() {
    local session="$1"

    # Lower-scope actions should not leave stale session-wide overrides behind.
    rm -f "$PARKED_DIR/${session}.parked"
    rm -f "$WAIT_DIR/${session}.wait"

    if session_is_fully_parked "$session"; then
        write_session_status "$session" "parked"
        return
    fi

    recompute_session_status "$session"
}

expire_wait_timers() {
    local current_time
    current_time=$(date +%s)
    local expired_count=0
    local wait_file=""
    local -A touched_sessions=()

    for wait_file in "$WAIT_DIR"/*.wait; do
        [ -f "$wait_file" ] || continue

        local expiry_time
        expiry_time=$(cat "$wait_file" 2>/dev/null || echo "")
        if [ -z "$expiry_time" ] || [ "$current_time" -lt "$expiry_time" ]; then
            continue
        fi

        local wait_name session pane_id pane_status_file
        wait_name=$(basename "$wait_file" .wait)
        session="$wait_name"
        pane_id=""

        if [[ "$wait_name" == *_%* ]]; then
            pane_id="${wait_name##*_}"
            if [[ "$pane_id" == %* ]]; then
                session="${wait_name%_${pane_id}}"
            else
                pane_id=""
            fi
        fi

        rm -f "$wait_file"

        if [ -n "$pane_id" ]; then
            pane_status_file="$PANE_DIR/${session}_${pane_id}.status"
            if [ -f "$pane_status_file" ] && [ "$(cat "$pane_status_file" 2>/dev/null || echo "")" = "wait" ]; then
                echo "done" > "$pane_status_file" 2>/dev/null
            fi
        fi

        touched_sessions["$session"]=1
        expired_count=$((expired_count + 1))
    done

    if [ "$expired_count" -gt 0 ]; then
        local session=""
        for session in "${!touched_sessions[@]}"; do
            recompute_session_status "$session"
        done
    fi

    echo "$expired_count"
}

get_pane_status() {
    local session="$1"
    local pane_id="$2"
    local pane_status="$PANE_DIR/${session}_${pane_id}.status"
    local pane_wait="$WAIT_DIR/${session}_${pane_id}.wait"
    local pane_parked="$PARKED_DIR/${session}_${pane_id}.parked"

    if [ -f "$pane_parked" ]; then
        echo "parked"
        return
    fi

    if [ -f "$pane_wait" ]; then
        local now expiry
        printf -v now '%(%s)T' -1
        expiry=$(cat "$pane_wait" 2>/dev/null || echo "")
        if [ -n "$expiry" ] && [ "$expiry" -gt "$now" ] 2>/dev/null; then
            echo "wait"
            return
        fi
        rm -f "$pane_wait"
        if [ -f "$pane_status" ] && [ "$(cat "$pane_status" 2>/dev/null || echo "")" = "wait" ]; then
            echo "done" > "$pane_status" 2>/dev/null
        fi
    fi

    if [ -f "$pane_status" ]; then
        cat "$pane_status" 2>/dev/null || echo ""
        return
    fi

    get_agent_status "$session"
}

get_window_status() {
    local session="$1"
    local window_index="$2"
    local best_status=""
    local best_priority=0
    local pane_id=""

    while IFS= read -r pane_id; do
        [ -z "$pane_id" ] && continue

        local pane_status pane_priority
        pane_status=$(get_pane_status "$session" "$pane_id")
        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done < <(tmux list-panes -t "${session}:${window_index}" -F "#{pane_id}" 2>/dev/null)

    if [ -n "$best_status" ]; then
        echo "$best_status"
    else
        get_agent_status "$session"
    fi
}

get_agent_status() {
    local session="$1"

    if session_is_fully_parked "$session"; then
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
        local status
        status=$(cat "$status_file" 2>/dev/null || echo "")
        if [ "$status" = "parked" ] && ! session_is_fully_parked "$session"; then
            recompute_session_status "$session"
            status=$(cat "$status_file" 2>/dev/null || echo "")
        fi
        if [ "$status" = "wait" ] && [ ! -f "$WAIT_DIR/${session}.wait" ]; then
            recompute_session_status "$session"
            status=$(cat "$status_file" 2>/dev/null || echo "")
        fi
        printf '%s\n' "$status"
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
