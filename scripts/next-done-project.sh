#!/usr/bin/env bash

# Cycle through done Claude panes across all windows.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"

PANE_DIR="$STATUS_DIR/panes"
session=$(tmux display-message -p "#{session_name}")
current_pane=$(tmux display-message -p "#{pane_id}")

# Collect all done panes in stable window order
targets=()
for win in $(tmux list-windows -t "$session" -F "#{window_index}"); do
    while IFS= read -r pid; do
        sf="$PANE_DIR/${session}_${pid}.status"
        [ -f "$sf" ] && [ "$(<"$sf")" = "done" ] && targets+=("$win:$pid")
    done < <(tmux list-panes -t "$session:$win" -F "#{pane_id}")
done

if [ ${#targets[@]} -eq 0 ]; then
    tmux display-message "No done panes"
    exit 1
fi

# Find current position, pick next
current_index=-1
for i in "${!targets[@]}"; do
    [[ "${targets[$i]}" == *":$current_pane" ]] && { current_index=$i; break; }
done
next_index=$(( (current_index + 1) % ${#targets[@]} ))

win="${targets[$next_index]%%:*}"
pane="${targets[$next_index]#*:}"
tmux select-window -t "$session:$win" \; select-pane -t "$pane"
