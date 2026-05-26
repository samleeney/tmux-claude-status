#!/usr/bin/env bash

# fzf inbox switcher — flat list of panes that need attention
# (working, done, ask, wait). Skips parked panes. Tab toggles a
# preview of the hovered pane; Enter switches to it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"

POPUP_COMPACT_WIDTH=60
POPUP_COMPACT_HEIGHT=14
POPUP_PREVIEW_WIDTH=120
POPUP_PREVIEW_HEIGHT=32
POPUP_TITLE=" Agent Inbox "
REFRESH_INTERVAL=2

status_icon() {
    case "$1" in
        working) printf '\033[1;33m⣾\033[0m' ;;
        done)    printf '\033[1;32m✓\033[0m' ;;
        ask)     printf '\033[1;31m?\033[0m' ;;
        wait)    printf '\033[1;36m⏸\033[0m' ;;
        *)       printf '\033[90m·\033[0m' ;;
    esac
}

emit_rows() {
    local line session pane_id win_idx win_name cmd status agent_file agent label
    while IFS=$'\t' read -r session pane_id win_idx win_name cmd; do
        [ -n "$pane_id" ] || continue

        status=$(get_pane_status "$session" "$pane_id")
        case "$status" in
            working|done|ask|wait) ;;
            *) continue ;;
        esac

        agent=""
        agent_file="$PANE_DIR/${session}_${pane_id}.agent"
        [ -f "$agent_file" ] && agent=$(<"$agent_file")

        label=$(printf '%s  %-7s  %s:%s.%s  %s%s' \
            "$(status_icon "$status")" "$status" "$session" "$win_idx" "${pane_id#%}" \
            "${agent:+[$agent] }" "$win_name")

        printf '%s\t%s\n' "$pane_id" "$label"
    done < <(tmux list-panes -a -F '#{session_name}'$'\t''#{pane_id}'$'\t''#{window_index}'$'\t''#{window_name}'$'\t''#{pane_current_command}' 2>/dev/null)
}

quote_args() {
    local out=""
    local arg
    for arg in "$@"; do
        out+=$(printf '%q ' "$arg")
    done
    printf '%s' "$out"
}

reopen_popup() {
    local preview_visible="$1"
    local initial_pane="$2"
    local width=$POPUP_COMPACT_WIDTH
    local height=$POPUP_COMPACT_HEIGHT
    local args reopen_cmd

    if [ "$preview_visible" = "1" ]; then
        width=$POPUP_PREVIEW_WIDTH
        height=$POPUP_PREVIEW_HEIGHT
    fi

    args=$(quote_args "$0" --preview-visible "$preview_visible" --initial-pane "$initial_pane")
    reopen_cmd=$(printf 'sleep 0.05; tmux display-popup -E -w %q -h %q -T %q -S fg=colour250 -s fg=colour250 %s' \
        "$width" "$height" "$POPUP_TITLE" "$args")
    tmux run-shell -b "$reopen_cmd"
}

switch_to_pane() {
    local pane_id="$1"
    local session win_idx
    [ -n "$pane_id" ] || return 0

    session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)
    win_idx=$(tmux display-message -p -t "$pane_id" '#{window_index}' 2>/dev/null || true)
    [ -n "$session" ] || return 0

    tmux switch-client -t "$session" 2>/dev/null || true
    [ -n "$win_idx" ] && tmux select-window -t "${session}:${win_idx}" 2>/dev/null || true
    tmux select-pane -t "$pane_id" 2>/dev/null || true
}

# --rows is the live-refresh hook used by fzf reload.
case "${1:-}" in
    --rows)
        emit_rows
        exit 0
        ;;
esac

PREVIEW_VISIBLE=0
INITIAL_PANE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --preview-visible) PREVIEW_VISIBLE="${2:-0}"; shift 2 ;;
        --initial-pane)    INITIAL_PANE="${2:-}";    shift 2 ;;
        *)                 shift ;;
    esac
done

rows_output=$(emit_rows)
if [ -z "$rows_output" ]; then
    tmux display-message "📭  agent inbox is empty"
    exit 0
fi

# Live refresh via fzf --listen: poke fzf every REFRESH_INTERVAL seconds.
state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-inbox.XXXXXX")
socket="$state_dir/fzf.sock"
refresh_action=$(printf 'reload(%q --rows)+refresh-preview' "$0")
trap 'rm -rf "$state_dir"' EXIT

if command -v curl >/dev/null 2>&1; then
    (
        while [ ! -S "$socket" ]; do sleep 0.1; done
        while [ -S "$socket" ]; do
            curl --silent --unix-socket "$socket" -X POST http://localhost \
                -d "$refresh_action" >/dev/null 2>&1 || break
            sleep "$REFRESH_INTERVAL"
        done
    ) &
    refresh_pid=$!
    trap 'kill "$refresh_pid" 2>/dev/null || true; rm -rf "$state_dir"' EXIT
fi

preview_window='right,65%,border-left,wrap,hidden'
[ "$PREVIEW_VISIBLE" = "1" ] && preview_window='right,65%,border-left,wrap'

initial_pos=""
if [ -n "$INITIAL_PANE" ]; then
    line_no=1
    while IFS=$'\t' read -r row_pane _; do
        if [ "$row_pane" = "$INITIAL_PANE" ]; then
            initial_pos="$line_no"
            break
        fi
        line_no=$((line_no + 1))
    done <<< "$rows_output"
fi

fzf_args=(
    --ansi
    --with-nth=2..
    --delimiter=$'\t'
    --listen="$socket"
    --track
    --id-nth=1
    --no-sort
    --reverse
    --info=inline
    --border=none
    --preview='tmux capture-pane -e -p -t {1} -S -120 2>/dev/null'
    --preview-window="$preview_window"
    --expect=tab
    --prompt='› '
)
[ -n "$initial_pos" ] && fzf_args+=(--bind="start:pos($initial_pos)")

fzf_output=$(printf '%s\n' "$rows_output" | fzf "${fzf_args[@]}") || exit 0
[ -n "$fzf_output" ] || exit 0

# --expect=tab makes fzf print the key on its own first line. When the user
# presses Enter, that line is empty and the selection follows.
key="${fzf_output%%$'\n'*}"
selection="${fzf_output#*$'\n'}"
[ "$selection" != "$fzf_output" ] || selection="$fzf_output"
target=${selection%%$'\t'*}

if [ "$key" = "tab" ]; then
    next_preview_visible=1
    [ "$PREVIEW_VISIBLE" = "1" ] && next_preview_visible=0
    reopen_popup "$next_preview_visible" "$target"
    exit 0
fi

switch_to_pane "$target"
