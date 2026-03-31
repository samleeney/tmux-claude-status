#!/usr/bin/env bash

# Sidebar data collector daemon.
# One instance per tmux server. Sources lib/collect.sh for data collection
# and writes a cache file that all sidebar renderers read from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"
source "$SCRIPT_DIR/lib/collect.sh"

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
PID_FILE="$STATUS_DIR/.sidebar-collector.pid"

# Singleton guard
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# Persistent cross-cycle state (survives across collect_data calls)
declare -A KNOWN_AGENTS=()
declare -A LIVE_PANES=()
declare -A PID_PPID=()
declare -A PANE_COUNTS=()
ENTRIES=()
SEL_NAMES=()
SEL_TYPES=()
SESS_START=0
_COLLECT_TICK=0
_LAST_STATUS_MTIME=""
_COLLECT_CHANGED=0

_tab=$'\t'

serialize_cache() {
    {
        echo "TS:$(date +%s)"
        echo "SESS_START:$SESS_START"
        for sname in "${!PANE_COUNTS[@]}"; do
            echo "PC:${sname}:${PANE_COUNTS[$sname]}"
        done
        local si=0
        for entry in "${ENTRIES[@]}"; do
            local etype="${entry%%|*}"
            if [[ "$etype" == "G" ]]; then
                echo "E:${entry}"
            else
                printf 'R:%s\t%s\t%s\n' "$entry" "${SEL_NAMES[$si]}" "${SEL_TYPES[$si]}"
                ((si++))
            fi
        done
    } > "${CACHE_FILE}.tmp"
    mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE"
}

while true; do
    tmux list-sessions >/dev/null 2>&1 || exit 0
    collect_data
    if (( _COLLECT_CHANGED )); then
        serialize_cache
    fi
    sleep 1
done
