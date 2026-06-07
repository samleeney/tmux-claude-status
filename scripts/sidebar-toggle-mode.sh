#!/usr/bin/env bash

# Toggle the sidebar between tree mode (sessions/windows/INBOX, default)
# and agents mode (only sessions/worktrees with agent panes, every agent
# expanded). Bound via @agent-sidebar-mode-key.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"

MODE_FILE="$STATUS_DIR/.sidebar-mode"
current=tree
[ -f "$MODE_FILE" ] && current=$(<"$MODE_FILE")

case "${1:-toggle}" in
    tree|agents) next="$1" ;;
    toggle|*)
        if [ "$current" = "agents" ]; then next=tree; else next=agents; fi
        ;;
esac

printf '%s' "$next" > "$MODE_FILE"

# Force the collector to re-run on its next tick by bumping the refresh
# file (collect_data stats it as part of cache-bust detection), then
# nudge sidebar clients so they redraw immediately once the cache lands.
"$SCRIPT_DIR/sidebar-signal.sh" collect
"$SCRIPT_DIR/sidebar-collector.sh" --once >/dev/null 2>&1 || true
"$SCRIPT_DIR/sidebar-signal.sh" refresh
