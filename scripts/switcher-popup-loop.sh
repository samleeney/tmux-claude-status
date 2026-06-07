#!/usr/bin/env bash

# Popup-loop wrapper for hook-based-switcher.sh.
# tmux popups can't be resized in-flight, so when the user toggles mode
# (ctrl-f) or preview (tab in agents mode), the inner script writes a
# relaunch sentinel and aborts fzf — we then relaunch the popup with
# dimensions matched to the new (mode, preview_hidden) state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER="$SCRIPT_DIR/hook-based-switcher.sh"

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-status-switcher.XXXXXX")
trap 'rm -rf "$state_dir"' EXIT

initial_mode="${TMUX_AGENT_SWITCHER_MODE:-tree}"
case "$initial_mode" in tree|agents) ;; *) initial_mode=tree ;; esac
printf '%s' "$initial_mode" > "$state_dir/mode"

# Preview defaults: hidden in tree mode, visible in agents mode.
if [ "$initial_mode" = "agents" ]; then
    printf '0' > "$state_dir/preview-hidden"
else
    printf '1' > "$state_dir/preview-hidden"
fi

while true; do
    rm -f "$state_dir/relaunch"

    mode=$(<"$state_dir/mode")
    preview_hidden=$(<"$state_dir/preview-hidden")

    # When preview is hidden, use the original fixed 60×14 popup — that
    # size worked well in practice. When preview is visible we need room
    # for the 65%-wide preview pane, so use a percent of the screen.
    if [ "$preview_hidden" = "1" ]; then
        W=60
        H=14
    else
        W="75%"
        H="60%"
    fi

    tmux display-popup -E \
        -w "$W" -h "$H" \
        -T " Switch Pane " \
        -S fg=colour250 -s fg=colour250 \
        "env TMUX_AGENT_SWITCHER_STATE_DIR='$state_dir' '$INNER'" \
        || true

    [ -f "$state_dir/relaunch" ] || break
done
