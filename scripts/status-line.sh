#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows agent status across all sessions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
LAST_STATUS_FILE="/tmp/tmux-agent-last-status-summary"

# Check and expire wait timers (session-level and per-pane)
check_wait_timers() {
    local wait_dir="$WAIT_DIR"
    [ ! -d "$wait_dir" ] && return
    local current_time=$(date +%s)
    local pane_dir="$STATUS_DIR/panes"

    for wait_file in "$wait_dir"/*.wait; do
        [ ! -f "$wait_file" ] && continue
        local bname=$(basename "$wait_file" .wait)
        local expiry_time=$(cat "$wait_file" 2>/dev/null)
        [ -z "$expiry_time" ] && continue
        [ "$current_time" -lt "$expiry_time" ] && continue

        # Expired — determine if per-pane or session-level
        if [[ "$bname" == *_%* ]]; then
            # Per-pane: e.g. "session_%5"
            echo "done" > "$pane_dir/${bname}.status" 2>/dev/null
            rm -f "$wait_file"
            # If no more per-pane waits for this session, clear session wait too
            local session="${bname%%_\%*}"
            local has_remaining=0
            for remaining in "$wait_dir/${session}_"*.wait; do
                [ -f "$remaining" ] && { has_remaining=1; break; }
            done
            if [ "$has_remaining" -eq 0 ]; then
                rm -f "$wait_dir/${session}.wait" 2>/dev/null
                echo "done" > "$STATUS_DIR/${session}.status" 2>/dev/null
                [ -f "$STATUS_DIR/${session}-remote.status" ] && echo "done" > "$STATUS_DIR/${session}-remote.status" 2>/dev/null
            fi
        else
            # Session-level
            echo "done" > "$STATUS_DIR/${bname}.status" 2>/dev/null
            [ -f "$STATUS_DIR/${bname}-remote.status" ] && echo "done" > "$STATUS_DIR/${bname}-remote.status" 2>/dev/null
            rm -f "$wait_file"
            # Also expire any per-pane waits for this session
            for pane_wait in "$wait_dir/${bname}_"*.wait; do
                [ -f "$pane_wait" ] || continue
                local pane_bname=$(basename "$pane_wait" .wait)
                echo "done" > "$pane_dir/${pane_bname}.status" 2>/dev/null
                rm -f "$pane_wait"
            done
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

    # When Codex is handling a turn it spawns subprocesses under the deepest
    # codex runner. When idle, the runner normally has no child processes.
    pgrep -P "$worker_pid" >/dev/null 2>&1
}

check_agent_processes() {
    while IFS= read -r session; do
        [ -z "$session" ] && continue
        local status_file="$STATUS_DIR/${session}.status"

        # Skip sessions with explicit user overrides — only UserPromptSubmit unparks/unwaits.
        [ -f "$PARKED_DIR/${session}.parked" ] && continue
        [ -f "$WAIT_DIR/${session}.wait" ] && continue

        local codex_pid=""
        codex_pid=$(find_session_codex_pid "$session" 2>/dev/null)

        if [ -n "$codex_pid" ]; then
            local current_status
            current_status=$(cat "$status_file" 2>/dev/null)
            if [ -z "$current_status" ]; then
                echo "working" > "$status_file"
            elif codex_session_is_working "$codex_pid"; then
                # Only auto-transition from done → working.
                if [ "$current_status" = "done" ]; then
                    echo "working" > "$status_file"
                fi
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
    local asking=0
    local unread=0
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
                    "done")
                        if [ -f "$STATUS_DIR/${session}.unread" ] || [ -f "$STATUS_DIR/${session}-remote.unread" ]; then
                            ((unread++))
                        else
                            ((done++))
                        fi
                        ((total_agents++))
                        ;;
                    "wait") ((waiting++)); ((total_agents++)) ;;
                    "ask") ((asking++)); ((total_agents++)) ;;
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
                    "done")
                        if [ -f "$STATUS_DIR/${session}.unread" ] || [ -f "$STATUS_DIR/${session}-remote.unread" ]; then
                            ((unread++))
                        else
                            ((done++))
                        fi
                        ((total_agents++))
                        ;;
                    "wait") ((waiting++)); ((total_agents++)) ;;
                    "ask") ((asking++)); ((total_agents++)) ;;
                esac
            fi
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)

    echo "$working:$waiting:$asking:$unread:$done:$total_agents"
}

# Play notification sound
play_notification() {
    "$SCRIPT_DIR/play-sound.sh" &
}

# Get current status
IFS=':' read -r working waiting asking unread done total_agents <<< "$(count_agent_status)"

# Load previous status. Older versions stored only the working count; skip
# notification diffing until we've written the new multi-count format once.
prev_done=""
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_status=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "")
    if [[ "$prev_status" == *:* ]]; then
        IFS=':' read -r _ _ _ prev_done <<< "$prev_status"
    fi
fi

# Save current status counts
echo "$working:$waiting:$asking:$unread:$done" > "$LAST_STATUS_FILE"

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

format_asking_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=cyan,bold]? 1 asking#[default]"
    else
        echo "#[fg=cyan,bold]? $count asking#[default]"
    fi
}

format_unread_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=magenta,bold]! 1 unread#[default]"
    else
        echo "#[fg=magenta,bold]! $count unread#[default]"
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
elif [ "$working" -eq 0 ] && [ "$waiting" -eq 0 ] && [ "$asking" -eq 0 ] && [ "$unread" -eq 0 ] && [ "$done" -gt 0 ]; then
    # All agents are done (and read)
    echo "#[fg=green,bold]✓ All agents ready#[default]"
else
    segments=()
    [ "$working" -gt 0 ] && segments+=("$(format_working_segment "$working")")
    [ "$asking" -gt 0 ] && segments+=("$(format_asking_segment "$asking")")
    [ "$unread" -gt 0 ] && segments+=("$(format_unread_segment "$unread")")
    [ "$waiting" -gt 0 ] && segments+=("$(format_waiting_segment "$waiting")")
    [ "$done" -gt 0 ] && segments+=("$(format_done_segment "$done")")
    printf '%s\n' "${segments[*]}"
fi
