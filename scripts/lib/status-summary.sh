#!/usr/bin/env bash

[[ -n "${_STATUS_SUMMARY_LOADED:-}" ]] && return 0
_STATUS_SUMMARY_LOADED=1

format_working_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ agent working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $count working#[default]"
    fi
}

format_waiting_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=cyan,bold]⏸ 1 waiting#[default]"
    else
        echo "#[fg=cyan,bold]⏸ $count waiting#[default]"
    fi
}

format_done_segment() {
    local count="$1"
    echo "#[fg=green]✓ $count done#[default]"
}

render_status_summary() {
    local working="$1"
    local waiting="$2"
    local done="$3"
    local total_agents="$4"
    local segments=()

    if [ "$total_agents" -eq 0 ]; then
        echo ""
    elif [ "$working" -eq 0 ] && [ "$waiting" -eq 0 ] && [ "$done" -gt 0 ]; then
        echo "#[fg=green,bold]✓ All agents ready#[default]"
    else
        [ "$working" -gt 0 ] && segments+=("$(format_working_segment "$working")")
        [ "$waiting" -gt 0 ] && segments+=("$(format_waiting_segment "$waiting")")
        [ "$done" -gt 0 ] && segments+=("$(format_done_segment "$done")")
        printf '%s\n' "${segments[*]}"
    fi
}

write_status_summary_cache() {
    local working="$1"
    local waiting="$2"
    local done="$3"
    local total_agents="$4"
    local summary

    summary="$(render_status_summary "$working" "$waiting" "$done" "$total_agents")"
    printf '%s\n' "$working:$waiting:$done:$total_agents" > "${STATUS_LINE_COUNTS_FILE}.tmp"
    mv -f "${STATUS_LINE_COUNTS_FILE}.tmp" "$STATUS_LINE_COUNTS_FILE"
    printf '%s\n' "$summary" > "${STATUS_LINE_CACHE_FILE}.tmp"
    mv -f "${STATUS_LINE_CACHE_FILE}.tmp" "$STATUS_LINE_CACHE_FILE"
}
