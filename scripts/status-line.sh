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
# Claude uses hooks; Codex lacks proper hooks so we detect it here
check_agent_processes() {
    while IFS= read -r session; do
        [ -z "$session" ] && continue
        local status_file="$STATUS_DIR/${session}.status"
        local has_codex=false

        # Check for codex process in session panes
        while IFS=: read -r pane_id pane_pid; do
            if pgrep -P "$pane_pid" -f "codex" >/dev/null 2>&1; then
                has_codex=true
                break
            fi
        done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)

        if [ "$has_codex" = true ]; then
            local current_status=$(cat "$status_file" 2>/dev/null)
            if [ "$current_status" != "working" ]; then
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
