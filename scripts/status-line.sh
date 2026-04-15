#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows agent status across all sessions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/status-summary.sh
source "$SCRIPT_DIR/lib/status-summary.sh"

LAST_STATUS_FILE="$STATUS_LINE_COUNTS_FILE"
COLLECTOR_PID_FILE="$STATUS_DIR/.sidebar-collector.pid"

collector_running=0
if [ -f "$COLLECTOR_PID_FILE" ]; then
    collector_pid=$(cat "$COLLECTOR_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$collector_pid" ] && kill -0 "$collector_pid" 2>/dev/null; then
        collector_running=1
    fi
fi

if (( collector_running )) && [ -f "$STATUS_LINE_CACHE_FILE" ]; then
    cat "$STATUS_LINE_CACHE_FILE"
    exit 0
fi

session_has_pane_status() {
    local session="$1"
    local pane_file

    for pane_file in "$PANE_DIR/${session}_"*.status; do
        [ -f "$pane_file" ] && return 0
    done

    return 1
}

# Check for agent processes (Codex) via process polling.
# Hook-managed sessions write per-pane status files, and those files are the
# authoritative source once they exist. Polling is only a bootstrap fallback
# for legacy or first-seen Codex sessions that do not have pane-level state yet.
# We detect active work by checking whether the deepest codex runner has
# spawned subprocesses for sandbox/tool execution.
find_session_codex_pid() {
    find_session_agent_pid "$1" "codex"
}

get_deepest_codex_pid() {
    local codex_pid="$1"
    local child_codex_pid=""

    while :; do
        child_codex_pid=$(pgrep -P "$codex_pid" -f "codex" 2>/dev/null | head -1)
        [ -z "$child_codex_pid" ] && break
        codex_pid="$child_codex_pid"
    done

    echo "$codex_pid"
}

codex_session_is_working() {
    local codex_pid="$1"
    [ -z "$codex_pid" ] && return 1

    local worker_pid
    worker_pid=$(get_deepest_codex_pid "$codex_pid")
    [ -z "$worker_pid" ] && return 1

    pgrep -P "$worker_pid" >/dev/null 2>&1
}

check_agent_processes() {
    while IFS= read -r session; do
        [ -z "$session" ] && continue
        local status_file="$STATUS_DIR/${session}.status"
        local wait_file="$STATUS_DIR/wait/${session}.wait"
        local parked_file="$PARKED_DIR/${session}.parked"
        local current_status=""
        local codex_pid=""

        # Parking is an explicit user decision — never auto-unpark.
        # Unparking only happens via user interaction (hook in better-hook.sh).
        if session_is_fully_parked "$session"; then
            continue
        fi

        current_status=$(cat "$status_file" 2>/dev/null)
        if session_has_pane_status "$session"; then
            continue
        fi

        codex_pid=$(find_session_codex_pid "$session" 2>/dev/null)

        if [ -n "$codex_pid" ]; then
            if [ -z "$current_status" ]; then
                # No status file yet — headless session or first detection
                echo "working" > "$status_file"
            elif codex_session_is_working "$codex_pid"; then
                case "$current_status" in
                    "done")
                        echo "working" > "$status_file"
                        ;;
                    "wait")
                        rm -f "$wait_file"
                        echo "working" > "$status_file"
                        ;;
                esac
            fi
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)
}

expire_wait_timers >/dev/null
check_agent_processes

# Count agent sessions by status
count_agent_status() {
    local working=0
    local waiting=0
    local done=0
    local total_agents=0

    # Check all tmux sessions including SSH remote status
    while IFS= read -r session; do
        [ -z "$session" ] && continue

        if session_is_fully_parked "$session"; then
            continue
        fi

        # Check for SSH remote status file (e.g., reachgpu-remote.status)
        local remote_status_file="$STATUS_DIR/${session}-remote.status"
        local status_file="$STATUS_DIR/${session}.status"

        # Check if we have any status for this session
        if [ -f "$remote_status_file" ] && is_ssh_session "$session"; then
            # SSH session with remote status
            local status=$(cat "$remote_status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                case "$status" in
                    "working") ((working++)); ((total_agents++)) ;;
                    "done") ((done++)); ((total_agents++)) ;;
                    "wait") ((waiting++)); ((total_agents++)) ;;
                esac
            fi
        elif [ -f "$remote_status_file" ] && ! is_ssh_session "$session"; then
            # A remote cache for a non-SSH session is stale and should not override
            # the local session status.
            rm -f "$remote_status_file" 2>/dev/null
            normalize_local_wait_status "$session"
            if [ -f "$status_file" ]; then
                local status=$(cat "$status_file" 2>/dev/null)
                if [ -n "$status" ]; then
                    case "$status" in
                        "working") ((working++)); ((total_agents++)) ;;
                        "done") ((done++)); ((total_agents++)) ;;
                        "wait") ((waiting++)); ((total_agents++)) ;;
                    esac
                fi
            fi
        elif [ -f "$status_file" ]; then
            # Local session status
            normalize_local_wait_status "$session"
            local status=$(cat "$status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                case "$status" in
                    "working") ((working++)); ((total_agents++)) ;;
                    "done") ((done++)); ((total_agents++)) ;;
                    "wait") ((waiting++)); ((total_agents++)) ;;
                esac
            fi
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)

    echo "$working:$waiting:$done:$total_agents"
}

# Get current status
IFS=':' read -r working waiting done total_agents <<< "$(count_agent_status)"

# Load previous status. Older versions stored only the working count; skip
# notification diffing until we've written the new multi-count format once.
prev_done=""
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_status=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "")
    if [[ "$prev_status" == *:* ]]; then
        IFS=':' read -r _ _ prev_done _ <<< "$prev_status"
    fi
fi

# Save current status counts
echo "$working:$waiting:$done:$total_agents" > "$LAST_STATUS_FILE"

# Check if any agent just finished (done count increased)
if [ -n "$prev_done" ] && [ "$done" -gt "$prev_done" ]; then
    "$SCRIPT_DIR/play-sound.sh" &
fi

render_status_summary "$working" "$waiting" "$done" "$total_agents"
