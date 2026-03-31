#!/usr/bin/env bash

# Cycle through all done panes: current session first, then others.
# Order: panes in current window → other windows → other sessions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"

PANE_DIR="$STATUS_DIR/panes"
current_session=$(tmux display-message -p "#{session_name}")
current_window=$(tmux display-message -p "#{window_index}")
current_pane=$(tmux display-message -p "#{pane_id}")

# Collect done panes for a session in window/pane order.
add_done_panes() {
    local sess="$1"
    for win in $(tmux list-windows -t "$sess" -F "#{window_index}" 2>/dev/null); do
        while IFS= read -r pid; do
            sf="$PANE_DIR/${sess}_${pid}.status"
            if [ -f "$sf" ]; then
                local st="$(<"$sf")"
                { [ "$st" = "done" ] || [ "$st" = "ask" ]; } && targets+=("$sess:$win:$pid")
            fi
        done < <(tmux list-panes -t "$sess:$win" -F "#{pane_id}" 2>/dev/null)
    done
}

targets=()
add_done_panes "$current_session"
for sess in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | sort); do
    [ "$sess" = "$current_session" ] && continue
    add_done_panes "$sess"
done

if [ ${#targets[@]} -eq 0 ]; then
    tmux display-message "No done panes"
    exit 1
fi

# Find current position, pick next
current_index=-1
for i in "${!targets[@]}"; do
    IFS=: read -r s w p <<< "${targets[$i]}"
    [ "$s" = "$current_session" ] && [ "$w" = "$current_window" ] && [ "$p" = "$current_pane" ] && {
        current_index=$i
        break
    }
done
next_index=$(( (current_index + 1) % ${#targets[@]} ))

IFS=: read -r sess win pane <<< "${targets[$next_index]}"
tmux switch-client -t "$sess" \; select-window -t "$sess:$win" \; select-pane -t "$pane"
