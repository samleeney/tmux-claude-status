#!/usr/bin/env bash

# fzf target switcher — hierarchical session/window/pane list with management actions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
WAIT_DIR="$STATUS_DIR/wait"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/selection-targets.sh
source "$SCRIPT_DIR/lib/selection-targets.sh"

status_icon() {
    case "$1" in
        working) printf '\033[1;33m⣾\033[0m' ;;
        done) printf '\033[1;32m✓\033[0m' ;;
        ask) printf '\033[1;31m?\033[0m' ;;
        wait) printf '\033[1;36m⏸\033[0m' ;;
        parked) printf '\033[1;35mP\033[0m' ;;
        *) printf '\033[90m·\033[0m' ;;
    esac
}

best_status_for_panes() {
    local session="$1"
    shift

    local best_status=""
    local best_priority=0
    local pane_id=""
    for pane_id in "$@"; do
        [ -n "$pane_id" ] || continue

        local pane_status pane_priority
        pane_status=$(get_pane_status "$session" "$pane_id")
        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done

    printf '%s\n' "$best_status"
}

pane_agent_badge() {
    local session="$1"
    local pane_id="$2"
    local agent=""

    [ -f "$PANE_DIR/${session}_${pane_id}.agent" ] && agent=$(< "$PANE_DIR/${session}_${pane_id}.agent")
    [ -n "$agent" ] && printf '  \033[2m(%s)\033[0m' "$agent"
}

SWITCHER_STATE_DIR=""
EXPANDED_SESSIONS_FILE=""
EXPANDED_WINDOWS_FILE=""

configure_state_dir() {
    SWITCHER_STATE_DIR="$1"
    [ -n "$SWITCHER_STATE_DIR" ] || return 0

    mkdir -p "$SWITCHER_STATE_DIR"
    EXPANDED_SESSIONS_FILE="$SWITCHER_STATE_DIR/expanded_sessions"
    EXPANDED_WINDOWS_FILE="$SWITCHER_STATE_DIR/expanded_windows"
    touch "$EXPANDED_SESSIONS_FILE" "$EXPANDED_WINDOWS_FILE"
}

state_has_line() {
    local file="$1"
    local needle="$2"

    [ -f "$file" ] && grep -Fxq -- "$needle" "$file"
}

state_add_line() {
    local file="$1"
    local needle="$2"

    [ -n "$file" ] || return 0
    state_has_line "$file" "$needle" && return 0
    printf '%s\n' "$needle" >> "$file"
}

state_remove_line() {
    local file="$1"
    local needle="$2"
    local tmp_file=""

    [ -f "$file" ] || return 0
    tmp_file="${file}.tmp.$$"
    awk -v needle="$needle" '$0 != needle { print }' "$file" > "$tmp_file"
    mv -f "$tmp_file" "$file"
}

state_remove_prefixed_lines() {
    local file="$1"
    local prefix="$2"
    local tmp_file=""

    [ -f "$file" ] || return 0
    tmp_file="${file}.tmp.$$"
    awk -v prefix="$prefix" 'index($0, prefix) != 1 { print }' "$file" > "$tmp_file"
    mv -f "$tmp_file" "$file"
}

session_expanded() {
    [ -n "$EXPANDED_SESSIONS_FILE" ] && state_has_line "$EXPANDED_SESSIONS_FILE" "$1"
}

window_expanded() {
    [ -n "$EXPANDED_WINDOWS_FILE" ] && state_has_line "$EXPANDED_WINDOWS_FILE" "$1"
}

toggle_expand() {
    local sel_name="$1"
    local sel_type="$2"
    local scope=""

    scope=$(selection_scope "$sel_name" "$sel_type") || return 0

    case "$scope" in
        session)
            if session_expanded "$sel_name"; then
                state_remove_line "$EXPANDED_SESSIONS_FILE" "$sel_name"
                state_remove_prefixed_lines "$EXPANDED_WINDOWS_FILE" "${sel_name}:w"
            else
                state_add_line "$EXPANDED_SESSIONS_FILE" "$sel_name"
            fi
            ;;
        window)
            if window_expanded "$sel_name"; then
                state_remove_line "$EXPANDED_WINDOWS_FILE" "$sel_name"
            else
                state_add_line "$EXPANDED_SESSIONS_FILE" "${sel_name%%:*}"
                state_add_line "$EXPANDED_WINDOWS_FILE" "$sel_name"
            fi
            ;;
    esac
}

get_switcher_rows() {
    local tab=$'\t'
    declare -A session_seen=()
    declare -A session_windows=()
    declare -A window_seen=()
    declare -A window_name=()
    declare -A window_panes=()
    declare -A pane_cmd=()
    local session_order=()
    local session="" pane_id="" win_idx="" win_name="" cmd="" pane_title=""

    while IFS=$'\t' read -r session pane_id win_idx win_name cmd pane_title; do
        [ -z "$session" ] && continue

        if [ -z "${session_seen[$session]:-}" ]; then
            session_seen[$session]=1
            session_order+=("$session")
        fi

        [ "$pane_title" = "agent-sidebar" ] && continue

        local window_key="${session}:${win_idx}"
        if [ -z "${window_seen[$window_key]:-}" ]; then
            window_seen[$window_key]=1
            session_windows[$session]+="${win_idx} "
            window_name[$window_key]="$win_name"
        fi

        window_panes[$window_key]+="${pane_id} "
        pane_cmd[$pane_id]="$cmd"
    done < <(tmux list-panes -a -F \
        "#{session_name}${tab}#{pane_id}${tab}#{window_index}${tab}#{window_name}${tab}#{pane_current_command}${tab}#{pane_title}" 2>/dev/null)

    for session in "${session_order[@]}"; do
        local win_list="${session_windows[$session]:-}"
        local session_panes=()
        local window_index=""
        for window_index in $win_list; do
            local session_window_key="${session}:${window_index}"
            local session_panes_string="${window_panes[$session_window_key]:-}"
            local session_pane=""
            for session_pane in $session_panes_string; do
                session_panes+=("$session_pane")
            done
        done

        local session_status session_icon
        session_status=$(best_status_for_panes "$session" "${session_panes[@]}")
        [ -z "$session_status" ] && session_status=$(get_agent_status "$session")
        session_icon=$(status_icon "$session_status")

        local session_marker="•"
        if [ -n "$win_list" ]; then
            if session_expanded "$session"; then
                session_marker="▾"
            else
                session_marker="▸"
            fi
        fi
        printf 'S\t%s\t%b  %s [session] %s\n' \
            "$session" "$session_icon" "$session_marker" "$session"

        session_expanded "$session" || continue

        for window_index in $win_list; do
            local window_key="${session}:${window_index}"
            local panes_string="${window_panes[$window_key]:-}"
            local panes=()
            local pane=""
            for pane in $panes_string; do
                panes+=("$pane")
            done

            local window_status window_icon
            window_status=$(best_status_for_panes "$session" "${panes[@]}")
            [ -z "$window_status" ] && window_status="$session_status"
            window_icon=$(status_icon "$window_status")
            local window_token="${session}:w${window_index}"
            local window_marker="•"
            if [ -n "$panes_string" ]; then
                if window_expanded "$window_token"; then
                    window_marker="▾"
                else
                    window_marker="▸"
                fi
            fi
            printf 'P\t%s:w%s\t%b    %s [window] %s / %s\n' \
                "$session" "$window_index" "$window_icon" "$window_marker" "$session" "${window_name[$window_key]}"

            window_expanded "$window_token" || continue

            for pane in "${panes[@]}"; do
                local pane_status pane_icon badge
                pane_status=$(get_pane_status "$session" "$pane")
                pane_icon=$(status_icon "$pane_status")
                badge=$(pane_agent_badge "$session" "$pane")
                printf 'P\t%s:%s\t%b      • [pane] %s / %s : %s%b\n' \
                    "$session" "$pane" "$pane_icon" "$session" "${window_name[$window_key]}" \
                    "${pane_cmd[$pane]:-shell}" "$badge"
            done
        done
    done
}

get_switcher_list() {
    get_switcher_rows | cut -f3-
}

dispatch_close_job() {
    local sel_name="$1"
    local sel_type="$2"
    local close_cmd=""

    printf -v close_cmd '%q ' "$SCRIPT_DIR/close-target.sh" "$sel_name" "$sel_type"
    tmux run-shell -b "$close_cmd"
}

perform_close() {
    local sel_name="$1"
    local sel_type="$2"

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        local prompt close_cmd confirm_cmd
        prompt=$(selection_close_prompt "$sel_name" "$sel_type")
        printf -v close_cmd '%q ' "$SCRIPT_DIR/close-target.sh" "$sel_name" "$sel_type"
        printf -v confirm_cmd 'run-shell -b %q' "$close_cmd"
        tmux confirm-before -p "$prompt" "$confirm_cmd"
        sleep 0.2
    else
        dispatch_close_job "$sel_name" "$sel_type"
        sleep 0.1
    fi
}

perform_popup_close() {
    local sel_name="$1"
    local sel_type="$2"

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        local prompt close_cmd confirm_cmd
        prompt=$(selection_close_prompt "$sel_name" "$sel_type")
        printf -v close_cmd '%q ' "$SCRIPT_DIR/close-target.sh" "$sel_name" "$sel_type"
        printf -v confirm_cmd 'run-shell -b %q' "$close_cmd"
        tmux confirm-before -b -p "$prompt" "$confirm_cmd"
    else
        dispatch_close_job "$sel_name" "$sel_type"
    fi
}

emit_close_fzf_actions() {
    local sel_name="$1"
    local sel_type="$2"

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        printf 'execute-silent(bash %q --popup-close %q %q)+abort\n' \
            "$0" "$sel_name" "$sel_type"
    else
        printf 'execute-silent(bash %q --state-dir %q --close %q %q)+reload(bash %q --state-dir %q --rows)\n' \
            "$0" "$SWITCHER_STATE_DIR" "$sel_name" "$sel_type" "$0" "$SWITCHER_STATE_DIR"
    fi
}

parse_args() {
    SWITCHER_COMMAND=""
    SWITCHER_ARG1=""
    SWITCHER_ARG2=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --state-dir)
                configure_state_dir "$2"
                shift 2
                ;;
            --rows|--list|--reset|--reset-rows)
                SWITCHER_COMMAND="$1"
                shift
                ;;
            --close|--popup-close|--toggle-expand|--close-fzf-actions)
                SWITCHER_COMMAND="$1"
                SWITCHER_ARG1="${2:-}"
                SWITCHER_ARG2="${3:-}"
                shift 3
                ;;
            *)
                return 0
                ;;
        esac
    done
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
parse_args "$@"

case "${SWITCHER_COMMAND:-}" in
    --rows)
        get_switcher_rows
        exit 0
        ;;
    --list)
        get_switcher_list
        exit 0
        ;;
    --close)
        perform_close "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --popup-close)
        perform_popup_close "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --toggle-expand)
        toggle_expand "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --close-fzf-actions)
        emit_close_fzf_actions "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --reset)
        perform_full_reset
        get_switcher_list
        exit 0
        ;;
    --reset-rows)
        perform_full_reset
        get_switcher_rows
        exit 0
        ;;
esac

# ─── Main: fzf picker ────────────────────────────────────────────
state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-status-switcher.XXXXXX")
trap 'rm -rf "$state_dir"' EXIT
configure_state_dir "$state_dir"

selected=$(get_switcher_rows | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=3.. \
    --no-sort \
    --no-preview \
    --prompt="  " \
    --header=$'\033[90mctrl-j/k scroll  tab expand/collapse  ctrl-x close  ctrl-p park  ctrl-w wait  ctrl-r reset\033[0m' \
    --header-first \
    --bind="ctrl-j:down,ctrl-k:up" \
    --bind="tab:execute-silent(bash '$0' --state-dir '$state_dir' --toggle-expand {2} {1})+reload(bash '$0' --state-dir '$state_dir' --rows)" \
    --bind="ctrl-p:execute-silent(bash '$SCRIPT_DIR/park-target.sh' {2} {1})+reload(bash '$0' --state-dir '$state_dir' --rows)" \
    --bind="ctrl-w:execute-silent(bash '$SCRIPT_DIR/wait-target.sh' {2} {1})+abort" \
    --bind="ctrl-r:reload(bash '$0' --state-dir '$state_dir' --reset-rows)" \
    --bind="ctrl-x:transform(bash '$0' --state-dir '$state_dir' --close-fzf-actions {2} {1})" \
    --layout=reverse \
    --info=hidden \
    --no-separator \
    --height=100% \
    --margin=0 \
    --padding=0)

# ─── Switch to selected target ────────────────────────────────────
if [ -n "$selected" ]; then
    IFS=$'\t' read -r sel_type sel_name _ <<< "$selected"
    selection_switch_client "$sel_name" "$sel_type"
fi
