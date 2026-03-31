#!/usr/bin/env bash

# Shared helpers for finding Claude/Codex processes inside tmux sessions.
# Uses an iterative BFS with a pre-built PID map to avoid recursive subshells.

# Global PID→children map and PID→args cache, built once per script invocation.
declare -A _AP_CHILDREN=()  # pid → space-separated child PIDs
declare -A _AP_ARGS=()      # pid → command args
_AP_MAP_BUILT=0

_build_agent_pid_map() {
    (( _AP_MAP_BUILT )) && return
    _AP_MAP_BUILT=1
    _AP_CHILDREN=()
    _AP_ARGS=()
    local pid ppid args
    while IFS= read -r line; do
        pid="${line%% *}"
        line="${line#* }"
        ppid="${line%% *}"
        args="${line#* }"
        [ -z "$pid" ] && continue
        [ -z "$ppid" ] && continue
        _AP_ARGS[$pid]="$args"
        _AP_CHILDREN[$ppid]+="$pid "
    done < <(ps -eo pid=,ppid=,args= 2>/dev/null)
}

find_matching_descendant_pid() {
    local root_pid="$1"
    local pattern="${2:-claude|codex}"

    _build_agent_pid_map

    # BFS using a simple queue (array + index)
    local queue=("$root_pid")
    local qi=0
    while (( qi < ${#queue[@]} )); do
        local cur="${queue[$qi]}"
        ((qi++))
        local cur_args="${_AP_ARGS[$cur]:-}"
        if [ -n "$cur_args" ] && [[ "$cur_args" =~ (^|[[:space:]/])($pattern)([[:space:]]|$) ]]; then
            echo "$cur"
            return 0
        fi
        # Enqueue children
        local children="${_AP_CHILDREN[$cur]:-}"
        if [ -n "$children" ]; then
            for child in $children; do
                queue+=("$child")
            done
        fi
    done
    return 1
}

find_session_agent_pid() {
    local session="$1"
    local pattern="${2:-claude|codex}"

    _build_agent_pid_map

    local pane_pids
    pane_pids=$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null) || return 1

    local pane_pid
    while IFS= read -r pane_pid; do
        [ -z "$pane_pid" ] && continue
        local match_pid
        match_pid=$(find_matching_descendant_pid "$pane_pid" "$pattern")
        if [ -n "$match_pid" ]; then
            echo "$match_pid"
            return 0
        fi
    done <<< "$pane_pids"

    return 1
}

session_has_agent_process() {
    local session="$1"
    local pattern="${2:-claude|codex}"

    find_session_agent_pid "$session" "$pattern" >/dev/null 2>&1
}
