#!/usr/bin/env bash

# Cycle through sessions that have done panes.
# Order: current session first (if it has done panes), then others alphabetically.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"

PANE_DIR="$STATUS_DIR/panes"
current_session=$(tmux display-message -p "#{session_name}")

# Find sessions with at least one done pane
declare -A has_done
for sf in "$PANE_DIR"/*.status; do
    [ -f "$sf" ] || continue
    [ "$(<"$sf")" = "done" ] || continue
    # Extract session name: filename is {session}_{pane_id}.status
    base="$(basename "$sf" .status)"
    sess="${base%_*}"
    # Verify session still exists
    tmux has-session -t "$sess" 2>/dev/null && has_done["$sess"]=1
done

if [ ${#has_done[@]} -eq 0 ]; then
    tmux display-message "No done sessions"
    exit 1
fi

# Build ordered list: current session first, then others sorted
targets=()
[ -n "${has_done[$current_session]:-}" ] && targets+=("$current_session")
for sess in $(printf '%s\n' "${!has_done[@]}" | sort); do
    [ "$sess" = "$current_session" ] && continue
    targets+=("$sess")
done

# Find current position, pick next
current_index=-1
for i in "${!targets[@]}"; do
    [ "${targets[$i]}" = "$current_session" ] && { current_index=$i; break; }
done
next_index=$(( (current_index + 1) % ${#targets[@]} ))

tmux switch-client -t "${targets[$next_index]}"
