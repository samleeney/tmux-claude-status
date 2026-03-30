#!/usr/bin/env bash

# Find and switch to the next 'done' project

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"

# Get current session
current_session=$(tmux display-message -p "#{session_name}")

# Check if we're being called with a session to exclude (from wait-session.sh)
exclude_session="$1"

# Collect all done sessions with their completion times
done_sessions_with_times=()
while IFS=: read -r name windows attached; do
    # Check if an agent is present
    agent_status=$(get_agent_status "$name")
    has_agent=false

    if has_agent_in_session "$name"; then
        has_agent=true
    elif [ -n "$agent_status" ] && is_ssh_session "$name"; then
        # SSH session with remote status
        has_agent=true
    fi

    if [ "$has_agent" = true ]; then
        [ -z "$agent_status" ] && agent_status="done"

        if [ "$agent_status" = "done" ] && [ "$name" != "$exclude_session" ]; then
            # Get completion time from status file modification time
            status_file=""
            if is_ssh_session "$name"; then
                status_file="$STATUS_DIR/${name}-remote.status"
            else
                status_file="$STATUS_DIR/${name}.status"
            fi

            completion_time=0
            if [ -f "$status_file" ]; then
                completion_time=$(stat -c %Y "$status_file" 2>/dev/null || echo 0)
            fi

            done_sessions_with_times+=("$completion_time:$name")
        fi
    fi
done < <(tmux list-sessions -F "#{session_name}:#{session_windows}:#{?session_attached,(attached),}" 2>/dev/null || echo "")

# Sort by completion time (most recent first) and extract session names
IFS=$'\n' sorted_sessions=($(printf '%s\n' "${done_sessions_with_times[@]}" | sort -t: -k1,1nr | cut -d: -f2-))
done_sessions=("${sorted_sessions[@]}")

# If no done sessions, exit
if [ ${#done_sessions[@]} -eq 0 ]; then
    tmux display-message "No done projects found"
    exit 1
fi

# Find current session index in done sessions
current_index=-1
for i in "${!done_sessions[@]}"; do
    if [ "${done_sessions[$i]}" = "$current_session" ]; then
        current_index=$i
        break
    fi
done

# Calculate next index
if [ $current_index -eq -1 ]; then
    # Current session not in done list, switch to most recent done session
    next_session="${done_sessions[0]}"
else
    # Switch to next done session (wrap around to most recent after last)
    next_index=$(( (current_index + 1) % ${#done_sessions[@]} ))
    next_session="${done_sessions[$next_index]}"
fi

# Switch to the next done session
tmux switch-client -t "$next_session"
tmux display-message "Switched to next done project: $next_session"
