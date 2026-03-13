#!/usr/bin/env bash

# Hook-based session switcher that reads status from files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

# Function to check if an agent (Claude or Codex) is in a session
has_agent_in_session() {
    session_has_agent_process "$1"
}

# Function to check if session is SSH by examining panes
is_ssh_session() {
    local session="$1"
    # Check if any pane in the session is running SSH
    if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
        return 0
    fi
    # Simple fallback: check if session name matches known SSH hosts
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}


# Function to get SSH host for session
get_ssh_host() {
    local session="$1"
    # For now, if it's an SSH session, assume the session name is the host
    # This is simple and works for most cases where session names match SSH config
    if is_ssh_session "$session"; then
        echo "$session"
    fi
}

# Function to get agent status from hook files
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

get_agent_status() {
    local session="$1"

    if [ -f "$PARKED_DIR/${session}.parked" ]; then
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
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get all sessions with formatted output
get_sessions_with_status() {
    local working_sessions=()
    local done_sessions=()
    local wait_sessions=()
    local parked_sessions=()
    local no_agent_sessions=()

    # Collect all sessions into arrays
    while IFS=: read -r name windows attached; do
        local formatted_line=""

        # Check if it's an SSH session
        local ssh_indicator=""
        if is_ssh_session "$name"; then
            ssh_indicator="[ssh]"
        fi

        # Check if an agent is present (local) or if we have remote status (SSH)
        local agent_status=$(get_agent_status "$name")
        local has_agent=false

        if has_agent_in_session "$name"; then
            has_agent=true
        elif [ "$agent_status" = "parked" ]; then
            has_agent=true
        elif [ -n "$agent_status" ] && is_ssh_session "$name"; then
            # SSH session with remote status
            has_agent=true
        else
            # Clean up stale status file if no agent is running
            if [ -n "$agent_status" ] && ! is_ssh_session "$name"; then
                rm -f "$STATUS_DIR/${name}.status" 2>/dev/null
            fi
        fi

        if [ "$has_agent" = true ]; then
            # Default to "done" if no status file exists
            [ -z "$agent_status" ] && agent_status="done"

            if [ "$agent_status" = "working" ]; then
                if [ -n "$ssh_indicator" ]; then
                    formatted_line=$(printf "%-20s %2s windows %-12s %s [working]" "$name" "$windows" "$attached" "$ssh_indicator")
                else
                    formatted_line=$(printf "%-20s %2s windows %-12s [working]" "$name" "$windows" "$attached")
                fi
                working_sessions+=("$formatted_line")
            elif [ "$agent_status" = "wait" ]; then
                # Calculate remaining wait time
                local wait_file="$STATUS_DIR/wait/${name}.wait"
                local wait_info=""
                if [ -f "$wait_file" ]; then
                    local expiry_time=$(cat "$wait_file" 2>/dev/null)
                    local current_time=$(date +%s)
                    local remaining=$(( expiry_time - current_time ))
                    if [ "$remaining" -gt 0 ]; then
                        local remaining_minutes=$(( remaining / 60 ))
                        wait_info="(${remaining_minutes}m)"
                    fi
                fi
                if [ -n "$ssh_indicator" ]; then
                    formatted_line=$(printf "%-20s %2s windows %-12s %s [wait] %s" "$name" "$windows" "$attached" "$ssh_indicator" "$wait_info")
                else
                    formatted_line=$(printf "%-20s %2s windows %-12s [wait] %s" "$name" "$windows" "$attached" "$wait_info")
                fi
                wait_sessions+=("$formatted_line")
            elif [ "$agent_status" = "parked" ]; then
                if [ -n "$ssh_indicator" ]; then
                    formatted_line=$(printf "%-20s %2s windows %-12s %s [parked]" "$name" "$windows" "$attached" "$ssh_indicator")
                else
                    formatted_line=$(printf "%-20s %2s windows %-12s [parked]" "$name" "$windows" "$attached")
                fi
                parked_sessions+=("$formatted_line")
            else
                if [ -n "$ssh_indicator" ]; then
                    formatted_line=$(printf "%-20s %2s windows %-12s %s [done]" "$name" "$windows" "$attached" "$ssh_indicator")
                else
                    formatted_line=$(printf "%-20s %2s windows %-12s [done]" "$name" "$windows" "$attached")
                fi
                done_sessions+=("$formatted_line")
            fi
        else
            if [ -n "$ssh_indicator" ]; then
                formatted_line=$(printf "%-20s %2s windows %-12s %s [no agent]" "$name" "$windows" "$attached" "$ssh_indicator")
            else
                formatted_line=$(printf "%-20s %2s windows %-12s [no agent]" "$name" "$windows" "$attached")
            fi
            no_agent_sessions+=("$formatted_line")
        fi
    done < <(tmux list-sessions -F "#{session_name}:#{session_windows}:#{?session_attached,(attached),}" 2>/dev/null || echo "")

    # Output grouped sessions with separators

    # Working sessions
    if [ ${#working_sessions[@]} -gt 0 ]; then
        echo -e "\033[1;33m WORKING \033[0m"
        printf '%s\n' "${working_sessions[@]}"
    fi

    # Done sessions
    if [ ${#done_sessions[@]} -gt 0 ]; then
        [ ${#working_sessions[@]} -gt 0 ] && echo
        echo -e "\033[1;32m DONE \033[0m"
        printf '%s\n' "${done_sessions[@]}"
    fi

    # Wait sessions
    if [ ${#wait_sessions[@]} -gt 0 ]; then
        [ ${#working_sessions[@]} -gt 0 ] || [ ${#done_sessions[@]} -gt 0 ] && echo
        echo -e "\033[1;36m WAIT \033[0m"
        printf '%s\n' "${wait_sessions[@]}"
    fi

    # Parked sessions
    if [ ${#parked_sessions[@]} -gt 0 ]; then
        [ ${#working_sessions[@]} -gt 0 ] || [ ${#done_sessions[@]} -gt 0 ] || [ ${#wait_sessions[@]} -gt 0 ] && echo
        echo -e "\033[1;35m PARKED \033[0m"
        printf '%s\n' "${parked_sessions[@]}"
    fi

    # No agent sessions
    if [ ${#no_agent_sessions[@]} -gt 0 ]; then
        [ ${#working_sessions[@]} -gt 0 ] || [ ${#done_sessions[@]} -gt 0 ] || [ ${#wait_sessions[@]} -gt 0 ] || [ ${#parked_sessions[@]} -gt 0 ] && echo
        echo -e "\033[1;90m NO AGENT \033[0m"
        printf '%s\n' "${no_agent_sessions[@]}"
    fi
}

# Handle --no-fzf flag for daemon refresh
if [ "$1" = "--no-fzf" ]; then
    get_sessions_with_status
    exit 0
fi

# Function to perform full reset
perform_full_reset() {
    # Stop daemons
    pkill -f "daemon-monitor.sh" 2>/dev/null
    pkill -f "smart-monitor.sh" 2>/dev/null

    # Clear only stale cache files, not active working status
    # Clear PID files
    find "$STATUS_DIR" -type f -name "*.pid" -delete 2>/dev/null

    # Clear wait files and normalize matching wait statuses back to done
    for wait_file in "$STATUS_DIR/wait"/*.wait; do
        [ ! -f "$wait_file" ] && continue
        session_name=$(basename "$wait_file" .wait)
        [ -f "$STATUS_DIR/${session_name}.status" ] && echo "done" > "$STATUS_DIR/${session_name}.status" 2>/dev/null
        [ -f "$STATUS_DIR/${session_name}-remote.status" ] && echo "done" > "$STATUS_DIR/${session_name}-remote.status" 2>/dev/null
        rm -f "$wait_file" 2>/dev/null
    done

    # Clear parked markers and normalize matching parked statuses back to done
    for parked_file in "$PARKED_DIR"/*.parked; do
        [ ! -f "$parked_file" ] && continue
        session_name=$(basename "$parked_file" .parked)
        if [ -f "$STATUS_DIR/${session_name}.status" ] && [ "$(cat "$STATUS_DIR/${session_name}.status" 2>/dev/null)" = "parked" ]; then
            echo "done" > "$STATUS_DIR/${session_name}.status" 2>/dev/null
        fi
        if [ -f "$STATUS_DIR/${session_name}-remote.status" ] && [ "$(cat "$STATUS_DIR/${session_name}-remote.status" 2>/dev/null)" = "parked" ]; then
            echo "done" > "$STATUS_DIR/${session_name}-remote.status" 2>/dev/null
        fi
        rm -f "$parked_file" 2>/dev/null
    done

    # Clear temp files
    rm -f "$STATUS_DIR"/.*.status.tmp 2>/dev/null

    # Check each status file and only remove if no agent is running in that session
    for status_file in "$STATUS_DIR"/*.status; do
        [ ! -f "$status_file" ] && continue

        # Extract session name from filename
        session_name=$(basename "$status_file" .status)

        # Skip remote status files
        if [[ "$session_name" == *"-remote" ]]; then
            continue
        fi

        # Check if an agent is actually running in this session
        if [ -f "$STATUS_DIR/wait/${session_name}.wait" ]; then
            continue
        fi

        status_value=$(cat "$status_file" 2>/dev/null)
        if [ "$status_value" = "wait" ] || [ "$status_value" = "parked" ]; then
            echo "done" > "$status_file" 2>/dev/null
        fi

        if ! has_agent_in_session "$session_name"; then
            # No agent running, safe to remove stale status
            rm -f "$status_file"
        fi
    done

    # Restart smart-monitor daemon
    "$SCRIPT_DIR/../smart-monitor.sh" stop >/dev/null 2>&1
    "$SCRIPT_DIR/../smart-monitor.sh" start >/dev/null 2>&1

    # Restart daemon monitor
    "$SCRIPT_DIR/daemon-monitor.sh" >/dev/null 2>&1 &
}

# Handle --reset flag for full reset
if [ "$1" = "--reset" ]; then
    perform_full_reset
    get_sessions_with_status
    exit 0
fi

# Main
sessions=$(get_sessions_with_status)

# Add the reminder at the bottom of the session list
sessions_with_reminder=$(echo -e "$(get_sessions_with_status)\n\n\033[1;36m Hit Ctrl-R to clear caches and reset everything! \033[0m")

# Use fzf with manual refresh (Ctrl-R)
selected=$(echo "$sessions_with_reminder" | fzf \
    --ansi \
    --no-sort \
    --header="Sessions grouped by agent status | j/k: navigate | Enter: select | Esc: cancel | Ctrl-R: full reset" \
    --preview 'if echo {} | grep -q "━━━\|───"; then echo "Category separator"; else session=$(echo {} | awk "{print \$1}"); tmux capture-pane -pJ -t "$session" 2>/dev/null | cat -s || echo "No preview available"; fi' \
    --preview-window=right:40% \
    --prompt="Session> " \
    --bind="j:down,k:up,ctrl-j:preview-down,ctrl-k:preview-up" \
    --bind="ctrl-r:reload(bash '$0' --reset)" \
    --layout=reverse \
    --info=inline)

# Switch to selected session (skip separator lines)
if [ -n "$selected" ] && ! echo "$selected" | grep -q "━━━\|───"; then
    session_name=$(echo "$selected" | awk '{print $1}')
    tmux switch-client -t "$session_name"
fi
