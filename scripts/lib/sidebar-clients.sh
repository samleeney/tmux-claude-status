#!/usr/bin/env bash

[[ -n "${_SIDEBAR_CLIENTS_LOADED:-}" ]] && return 0
_SIDEBAR_CLIENTS_LOADED=1

SIDEBAR_TITLE="${SIDEBAR_TITLE:-agent-sidebar}"

register_sidebar_client() {
    local pane_id="${1:-}"
    [ -n "$pane_id" ] || pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
    [ -n "$pane_id" ] || return 1

    mkdir -p "$SIDEBAR_CLIENT_DIR"
    printf '%s\n' "$$" > "$SIDEBAR_CLIENT_DIR/${pane_id}.pid"
    printf '%s\n' "$pane_id"
}

unregister_sidebar_client() {
    local pane_id="$1"
    [ -n "$pane_id" ] || return 0
    rm -f "$SIDEBAR_CLIENT_DIR/${pane_id}.pid"
}

signal_sidebar_clients() {
    local signal_name="$1"
    local scope="${2:-all}"
    local pane_file pane_id pid
    local -A pane_titles=()
    local -A pane_active=()

    for pane_file in "$SIDEBAR_CLIENT_DIR/"*.pid; do
        [ -f "$pane_file" ] || return 0
        break
    done

    while IFS=$'\t' read -r pane_id pane_title pane_is_active; do
        [ -n "$pane_id" ] || continue
        pane_titles[$pane_id]="$pane_title"
        pane_active[$pane_id]="${pane_is_active:-0}"
    done < <(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_title}'$'\t''#{pane_active}' 2>/dev/null)

    for pane_file in "$SIDEBAR_CLIENT_DIR/"*.pid; do
        [ -f "$pane_file" ] || continue

        pane_id="$(basename "$pane_file" .pid)"
        pid="$(cat "$pane_file" 2>/dev/null || echo "")"

        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pane_file"
            continue
        fi

        if [ "${pane_titles[$pane_id]:-}" != "$SIDEBAR_TITLE" ]; then
            rm -f "$pane_file"
            continue
        fi

        if [ "$scope" = "active" ] && [ "${pane_active[$pane_id]:-0}" != "1" ]; then
            continue
        fi

        kill -s "$signal_name" "$pid" 2>/dev/null || rm -f "$pane_file"
    done
}
