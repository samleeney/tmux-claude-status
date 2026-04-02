#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows agent status across all sessions

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
LAST_STATUS_FILE="$STATUS_DIR/.last-status-summary"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

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

# Check and expire wait timers
check_wait_timers() {
    local wait_dir="$STATUS_DIR/wait"
    [ ! -d "$wait_dir" ] && return
    local current_time=$(date +%s)
    for wait_file in "$wait_dir"/*.wait; do
        [ ! -f "$wait_file" ] && continue
        local session_name=$(basename "$wait_file" .wait)
        local expiry_time=$(cat "$wait_file" 2>/dev/null)
        if [ -n "$expiry_time" ] && [ "$current_time" -ge "$expiry_time" ]; then
            echo "done" > "$STATUS_DIR/${session_name}.status" 2>/dev/null
            # Only update remote status if it already exists (SSH sessions)
            [ -f "$STATUS_DIR/${session_name}-remote.status" ] && echo "done" > "$STATUS_DIR/${session_name}-remote.status" 2>/dev/null
            rm -f "$wait_file"
        fi
    done
}

normalize_local_wait_status() {
    local session="$1"
    local status_file="$STATUS_DIR/${session}.status"
    local wait_file="$STATUS_DIR/wait/${session}.wait"

    [ ! -f "$status_file" ] && return

    local status
    status=$(cat "$status_file" 2>/dev/null || echo "")
    if [ "$status" = "wait" ] && [ ! -f "$wait_file" ]; then
        echo "done" > "$status_file" 2>/dev/null
    fi
}

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
        if [ -f "$parked_file" ]; then
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

check_wait_timers
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

        local parked_file="$PARKED_DIR/${session}.parked"
        if [ -f "$parked_file" ]; then
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

# Play notification sound
play_notification() {
    "$SCRIPT_DIR/play-sound.sh" &
}

# Get current status
IFS=':' read -r working waiting done total_agents <<< "$(count_agent_status)"

# Load previous status. Older versions stored only the working count; skip
# notification diffing until we've written the new multi-count format once.
prev_done=""
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_status=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "")
    if [[ "$prev_status" == *:* ]]; then
        IFS=':' read -r _ _ prev_done <<< "$prev_status"
    fi
fi

# Save current status counts
echo "$working:$waiting:$done" > "$LAST_STATUS_FILE"

# Check if any agent just finished (done count increased)
if [ -n "$prev_done" ] && [ "$done" -gt "$prev_done" ]; then
    play_notification
fi

format_working_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ agent working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $count working#[default]"
    fi
}

format_waiting_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=cyan,bold]⏸ 1 waiting#[default]"
    else
        echo "#[fg=cyan,bold]⏸ $count waiting#[default]"
    fi
}

format_done_segment() {
    local count="$1"
    echo "#[fg=green]✓ $count done#[default]"
}

# Generate status line output
if [ "$total_agents" -eq 0 ]; then
    # No agent sessions
    echo ""
elif [ "$working" -eq 0 ] && [ "$waiting" -eq 0 ] && [ "$done" -gt 0 ]; then
    # All agents are done
    echo "#[fg=green,bold]✓ All agents ready#[default]"
else
    segments=()
    [ "$working" -gt 0 ] && segments+=("$(format_working_segment "$working")")
    [ "$waiting" -gt 0 ] && segments+=("$(format_waiting_segment "$waiting")")
    [ "$done" -gt 0 ] && segments+=("$(format_done_segment "$done")")
    printf '%s\n' "${segments[*]}"
fi
