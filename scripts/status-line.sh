#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows agent status across all sessions

STATUS_DIR="$HOME/.cache/tmux-agent-status"
LAST_STATUS_FILE="$STATUS_DIR/.last-status-summary"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Check for agent processes (Codex) via process polling
# Codex stays resident when idle, so we can only use process presence to:
#   1. Set initial "working" when no status file exists yet
#   2. Transition from "done" to "working" (user started a new prompt)
# The notify hook handles the "working" -> "done" transition.
# We detect active work by checking if codex has child processes (sandbox/tools).
find_session_codex_pid() {
    local session="$1"

    while IFS=: read -r pane_id pane_pid; do
        local found_pid
        found_pid=$(pgrep -P "$pane_pid" -f "codex" 2>/dev/null | head -1)
        if [ -n "$found_pid" ]; then
            echo "$found_pid"
            return 0
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)

    return 1
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

    # When Codex is handling a turn it spawns subprocesses under the deepest
    # codex runner. When idle, the runner normally has no child processes.
    pgrep -P "$worker_pid" >/dev/null 2>&1
}

check_agent_processes() {
    while IFS= read -r session; do
        [ -z "$session" ] && continue
        local status_file="$STATUS_DIR/${session}.status"
        local codex_pid=""

        codex_pid=$(find_session_codex_pid "$session" 2>/dev/null)

        if [ -n "$codex_pid" ]; then
            local current_status
            current_status=$(cat "$status_file" 2>/dev/null)
            if [ -z "$current_status" ]; then
                # No status file yet - first detection, assume working
                echo "working" > "$status_file"
            elif [ "$current_status" = "done" ] && codex_session_is_working "$codex_pid"; then
                echo "working" > "$status_file"
            fi
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)
}

check_wait_timers
check_agent_processes

# Count agent sessions by status
count_agent_status() {
    local working=0
    local done=0
    local total_agents=0

    # Check all tmux sessions including SSH remote status
    while IFS= read -r session; do
        [ -z "$session" ] && continue

        # Check for SSH remote status file (e.g., reachgpu-remote.status)
        local remote_status_file="$STATUS_DIR/${session}-remote.status"
        local status_file="$STATUS_DIR/${session}.status"

        # Check if we have any status for this session
        if [ -f "$remote_status_file" ]; then
            # SSH session with remote status
            local status=$(cat "$remote_status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                ((total_agents++))
                case "$status" in
                    "working") ((working++)) ;;
                    "done") ((done++)) ;;
                    "wait") ((working++)) ;;  # Treat wait as working for status line
                esac
            fi
        elif [ -f "$status_file" ]; then
            # Local session status
            local status=$(cat "$status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                ((total_agents++))
                case "$status" in
                    "working") ((working++)) ;;
                    "done") ((done++)) ;;
                    "wait") ((working++)) ;;  # Treat wait as working for status line
                esac
            fi
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)

    echo "$working:$done:$total_agents"
}

# Play notification sound
play_notification() {
    "$SCRIPT_DIR/play-sound.sh" &
}

# Get current status
IFS=':' read -r working done total_agents <<< "$(count_agent_status)"

# Load previous status
prev_working=0
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_working=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "0")
fi

# Save current working count
echo "$working" > "$LAST_STATUS_FILE"

# Check if any agent just finished (working count decreased)
if [ "$prev_working" -gt "$working" ] && [ "$prev_working" -gt 0 ]; then
    play_notification
fi

# Generate status line output
if [ "$total_agents" -eq 0 ]; then
    # No agent sessions
    echo ""
elif [ "$working" -eq 0 ] && [ "$done" -gt 0 ]; then
    # All agents are done
    echo "#[fg=green,bold]✓ All agents ready#[default]"
elif [ "$working" -gt 0 ] && [ "$done" -gt 0 ]; then
    # Some working, some done
    echo "#[fg=yellow,bold]⚡ $working working#[default] #[fg=green]✓ $done done#[default]"
elif [ "$working" -gt 0 ]; then
    # All agents are working
    if [ "$working" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ agent working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $working agents working#[default]"
    fi
fi
