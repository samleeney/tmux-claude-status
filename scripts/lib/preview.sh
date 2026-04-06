#!/usr/bin/env bash

# Shared preview-target helpers for the popup session switcher.

[[ -n "${_PREVIEW_LIB_LOADED:-}" ]] && return 0
_PREVIEW_LIB_LOADED=1

sidebar_preview_selection_key() {
    local sel_name="$1"
    local sel_type="$2"

    printf '%s|%s\n' "$sel_type" "$sel_name"
}

sidebar_preview_title() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        P)
            local sess="${sel_name%%:*}"
            local target="${sel_name#*:}"

            if [[ "$target" == w* ]]; then
                printf '%s | window %s\n' "$sess" "${target#w}"
            else
                printf '%s | %s\n' "$sess" "$target"
            fi
            ;;
        *)
            printf '%s\n' "$sel_name"
            ;;
    esac
}

sidebar_preview_target() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        P)
            local sess="${sel_name%%:*}"
            local target="${sel_name#*:}"

            if [[ "$target" == w* ]]; then
                printf '%s:%s\n' "$sess" "${target#w}"
            else
                printf '%s\n' "$target"
            fi
            ;;
        *)
            printf '%s\n' "$sel_name"
            ;;
    esac
}

sidebar_preview_metadata() {
    local sel_name="$1"
    local sel_type="$2"
    local target
    target=$(sidebar_preview_target "$sel_name" "$sel_type")

    local info
    info=$(tmux display-message -p -t "$target" '#{session_name}	#{window_index}	#{window_name}	#{pane_index}	#{pane_id}	#{pane_current_command}	#{pane_current_path}' 2>/dev/null || true)
    [ -z "$info" ] && return 0

    local session_name window_index window_name pane_index pane_id pane_cmd pane_path
    IFS=$'\t' read -r session_name window_index window_name pane_index pane_id pane_cmd pane_path <<< "$info"

    case "$sel_type" in
        P)
            local raw_target="${sel_name#*:}"
            if [[ "$raw_target" == w* ]]; then
                printf 'window %s: %s | active pane %s (%s) | %s\n' \
                    "$window_index" "$window_name" "$pane_index" "$pane_id" "${pane_cmd:-shell}"
            else
                printf 'pane %s (%s) | window %s: %s | %s\n' \
                    "$pane_index" "$pane_id" "$window_index" "$window_name" "${pane_cmd:-shell}"
            fi
            ;;
        *)
            printf 'active window %s: %s | pane %s (%s) | %s\n' \
                "$window_index" "$window_name" "$pane_index" "$pane_id" "${pane_cmd:-shell}"
            ;;
    esac

    [ -n "$pane_path" ] && printf '%s\n' "$pane_path"
}
