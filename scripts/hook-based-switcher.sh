#!/usr/bin/env bash

# fzf pane fuzzy finder — flat list of ALL panes with agent status icons

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
WAIT_DIR="$STATUS_DIR/wait"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"

# ─── Build flat pane list ─────────────────────────────────────────
get_pane_list() {
    local tab=$'\t'

    while IFS=$'\t' read -r session pane_id win_idx win_name pane_title pane_cmd; do
        [ -z "$session" ] && continue

        # Filter out sidebar panes
        [[ "$pane_title" == "agent-sidebar" ]] && continue

        # Determine pane status (parked marker > wait timer > status file > session fallback)
        local status=""
        if [ -f "$PARKED_DIR/${session}_${pane_id}.parked" ]; then
            status="parked"
        elif [ -f "$WAIT_DIR/${session}_${pane_id}.wait" ]; then
            local now exp
            printf -v now '%(%s)T' -1
            exp=$(< "$WAIT_DIR/${session}_${pane_id}.wait")
            if [ -n "$exp" ] && (( exp > now )); then
                status="wait"
            else
                status="done"
            fi
        elif [ -f "$PANE_DIR/${session}_${pane_id}.status" ]; then
            status=$(< "$PANE_DIR/${session}_${pane_id}.status")
        elif [ -f "$STATUS_DIR/${session}.status" ]; then
            status=$(< "$STATUS_DIR/${session}.status")
        fi

        # Agent type badge
        local agent=""
        [ -f "$PANE_DIR/${session}_${pane_id}.agent" ] && agent=$(< "$PANE_DIR/${session}_${pane_id}.agent")

        # Colored status icon
        local icon
        case "$status" in
            working) icon=$'\033[1;33m⣾\033[0m' ;;
            done)    icon=$'\033[1;32m✓\033[0m' ;;
            ask)     icon=$'\033[1;31m?\033[0m' ;;
            wait)    icon=$'\033[1;36m⏸\033[0m' ;;
            parked)  icon=$'\033[1;35mP\033[0m' ;;
            *)       icon=$'\033[90m·\033[0m' ;;
        esac

        local badge=""
        [ -n "$agent" ] && badge="  \033[2m($agent)\033[0m"

        printf '%s\t%b  %s / %s : %s%b\n' \
            "$pane_id" "$icon" "$session" "$win_name" "$pane_cmd" "$badge"

    done < <(tmux list-panes -a -F \
        "#{session_name}${tab}#{pane_id}${tab}#{window_index}${tab}#{window_name}${tab}#{pane_title}${tab}#{pane_current_command}" 2>/dev/null)
}

# ─── Full reset (shared with sidebar.sh) ──────────────────────────
perform_full_reset() {
    pkill -f "daemon-monitor.sh" 2>/dev/null
    pkill -f "smart-monitor.sh" 2>/dev/null

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

    # Clear temp files
    rm -f "$STATUS_DIR"/.*.status.tmp 2>/dev/null

    # Check each status file and only remove if no agent is running in that session
    for status_file in "$STATUS_DIR"/*.status; do
        [ ! -f "$status_file" ] && continue
        session_name=$(basename "$status_file" .status)
        [[ "$session_name" == *"-remote" ]] && continue

        if [ -f "$STATUS_DIR/wait/${session_name}.wait" ]; then
            continue
        fi

        if session_is_fully_parked "$session_name"; then
            if ! session_has_agent_process "$session_name"; then
                rm -f "$PARKED_DIR/${session_name}_"*.parked 2>/dev/null
                rm -f "$status_file"
            fi
            continue
        fi

        status_value=$(cat "$status_file" 2>/dev/null)
        if [ "$status_value" = "wait" ]; then
            echo "done" > "$status_file" 2>/dev/null
        fi

        if ! session_has_agent_process "$session_name"; then
            rm -f "$status_file"
        fi
    done

    # Restart daemons
    "$SCRIPT_DIR/../smart-monitor.sh" stop >/dev/null 2>&1
    "$SCRIPT_DIR/../smart-monitor.sh" start >/dev/null 2>&1
    "$SCRIPT_DIR/daemon-monitor.sh" </dev/null >/dev/null 2>&1 &
    disown
}

# ─── Flag dispatch ────────────────────────────────────────────────
case "${1:-}" in
    --list)
        get_pane_list
        exit 0
        ;;
    --reset)
        perform_full_reset
        get_pane_list
        exit 0
        ;;
esac

# ─── Main: fzf picker ────────────────────────────────────────────
selected=$(get_pane_list | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --no-sort \
    --no-preview \
    --prompt="  " \
    --bind="ctrl-r:reload(bash '$0' --reset)" \
    --layout=reverse \
    --info=hidden \
    --no-separator \
    --height=100% \
    --margin=0 \
    --padding=0)

# ─── Switch to selected pane ─────────────────────────────────────
if [ -n "$selected" ]; then
    pane_target="${selected%%	*}"
    info=$(tmux display-message -p -t "$pane_target" '#{session_name}	#{window_index}' 2>/dev/null)
    if [ -n "$info" ]; then
        session="${info%%	*}"
        window="${info#*	}"
        tmux switch-client -t "$session" 2>/dev/null
        tmux select-window -t "$session:$window" 2>/dev/null
        tmux select-pane -t "$pane_target" 2>/dev/null
    fi
fi
