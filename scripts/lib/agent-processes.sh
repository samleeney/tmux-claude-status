#!/usr/bin/env bash

# Shared helpers for finding Claude/Codex processes inside tmux sessions.

find_matching_descendant_pid() {
    local root_pid="$1"
    local pattern="${2:-claude|codex}"
    local process_args=""

    process_args=$(ps -p "$root_pid" -o args= 2>/dev/null || true)
    if [ -n "$process_args" ] && [[ "$process_args" =~ (^|[[:space:]/])($pattern)([[:space:]]|$) ]]; then
        echo "$root_pid"
        return 0
    fi

    while IFS= read -r child_pid; do
        [ -z "$child_pid" ] && continue

        local match_pid=""
        match_pid=$(find_matching_descendant_pid "$child_pid" "$pattern")
        if [ -n "$match_pid" ]; then
            echo "$match_pid"
            return 0
        fi
    done < <(pgrep -P "$root_pid" 2>/dev/null || true)

    return 1
}

find_session_agent_pid() {
    local session="$1"
    local pattern="${2:-claude|codex}"

    while IFS=: read -r _ pane_pid; do
        [ -z "$pane_pid" ] && continue

        local match_pid=""
        match_pid=$(find_matching_descendant_pid "$pane_pid" "$pattern")
        if [ -n "$match_pid" ]; then
            echo "$match_pid"
            return 0
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)

    return 1
}

session_has_agent_process() {
    local session="$1"
    local pattern="${2:-claude|codex}"

    find_session_agent_pid "$session" "$pattern" >/dev/null 2>&1
}
