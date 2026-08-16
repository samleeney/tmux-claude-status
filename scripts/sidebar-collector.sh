#!/usr/bin/env bash

# Sidebar data collector daemon.
# One instance per tmux server. Sources lib/collect.sh for data collection
# and writes a cache file that all sidebar renderers read from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"
source "$SCRIPT_DIR/lib/collect.sh"
source "$SCRIPT_DIR/lib/status-summary.sh"
source "$SCRIPT_DIR/lib/sidebar-clients.sh"

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
PID_FILE="$STATUS_DIR/.sidebar-collector.pid"
LOCK_DIR="$STATUS_DIR/.sidebar-collector.lock"
RUN_ONCE=0

# Poll tuning. The loop wakes every TICK_SECONDS purely to animate the spinner
# for active sessions, and runs the real (expensive) collection every
# TICKS_PER_COLLECT wakeups.
#
# The old values (0.25s tick, 4 ticks => 1s collect) cost ~7% of a CPU core
# continuously: 33 minutes of CPU in 7.4 hours of uptime, just to draw a
# status bar. 1s tick / 5s collect is visually fine and roughly 4x cheaper on
# wakeups and 5x cheaper on collection.
#
# Override in the environment if you want the old snappiness back:
#   TMUX_SIDEBAR_TICK_SECONDS=0.25 TMUX_SIDEBAR_TICKS_PER_COLLECT=4
TICK_SECONDS="${TMUX_SIDEBAR_TICK_SECONDS:-1}"
TICKS_PER_COLLECT="${TMUX_SIDEBAR_TICKS_PER_COLLECT:-5}"

if [[ "${1:-}" == "--once" ]]; then
    RUN_ONCE=1
fi

# Singleton guard - the persistent daemon only. A --once run does one collect_data +
# serialize_cache pass and exits on its own (see the RUN_ONCE check a few lines into the main
# loop below); it never loops, so it cannot double up with the daemon the way two persistent
# instances could, and it skips this lock entirely rather than fight the daemon for it.
#
# This used to be a plain "check the pid file, then write it" pair, which is two separate
# steps: two daemons starting close together could both pass the check before either had
# written, and both would end up running. It also shared one file with a --once run's own EXIT
# trap, so a --once process finishing while the real daemon was up could delete the daemon's
# own lock out from under it. mkdir is atomic - exactly one caller ever succeeds - so the real
# lock lives in LOCK_DIR now. PID_FILE stays a plain file with the winner's pid in it, purely so
# status-line.sh (which already reads it as a file, not a directory) keeps working unchanged.
if (( ! RUN_ONCE )); then
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            exit 0   # a live daemon already owns this
        fi
        # Stale: the previous owner died without running its EXIT trap (kill -9, crash).
        # Reclaim once; if another instance wins the retry, back off rather than loop.
        rm -rf "$LOCK_DIR" "$PID_FILE" 2>/dev/null
        mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -rf "$LOCK_DIR" "$PID_FILE"' EXIT
fi

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
SUMMARY_WORKING=0
SUMMARY_WAITING=0
SUMMARY_DONE=0
SUMMARY_TOTAL=0
SUMMARY_HAS_WORKING=0
SUMMARY_AGENTS=()

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

publish_status_summary() {
    local prev_done=""

    if [ -f "$STATUS_LINE_COUNTS_FILE" ]; then
        IFS=: read -r _ _ prev_done _ < "$STATUS_LINE_COUNTS_FILE"
    fi

    write_status_summary_cache \
        "$SUMMARY_WORKING" \
        "$SUMMARY_WAITING" \
        "$SUMMARY_DONE" \
        "$SUMMARY_TOTAL" \
        "${SUMMARY_AGENTS[@]}"

    if (( ! RUN_ONCE )) && [ -n "$prev_done" ] && [ "$SUMMARY_DONE" -gt "$prev_done" ]; then
        "$SCRIPT_DIR/play-sound.sh" &
    fi
}

tick=0
while true; do
    tmux list-sessions >/dev/null 2>&1 || exit 0

    if (( tick == 0 )); then
        collect_data
        if (( _COLLECT_CHANGED )); then
            serialize_cache
            publish_status_summary
            (( ! RUN_ONCE )) && signal_sidebar_clients USR1 all
        fi
    fi

    if (( RUN_ONCE )); then
        exit 0
    fi

    if (( SUMMARY_HAS_WORKING )); then
        signal_sidebar_clients USR2 active
    fi

    sleep "$TICK_SECONDS"
    tick=$(( (tick + 1) % TICKS_PER_COLLECT ))
done
