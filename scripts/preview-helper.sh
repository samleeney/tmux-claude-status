#!/usr/bin/env bash

# Preview helper for fzf session switcher.
# Extracted from inline --preview to handle edge cases cleanly.
# Inspired by the original upstream preview helper workflow.

input="$1"

# Category separator lines
if echo "$input" | grep -q "━━━\|───"; then
    echo "Select a session below to see its preview"
    exit 0
fi

# Ctrl-R reminder line
if echo "$input" | grep -q "Hit Ctrl-R"; then
    echo "Press Ctrl-R to refresh the session list"
    exit 0
fi

# Empty lines
if [ -z "$input" ] || [ "$input" = " " ]; then
    exit 0
fi

# Extract session name and show pane content
session=$(echo "$input" | awk '{print $1}')
if [ -n "$session" ]; then
    tmux capture-pane -pJ -t "$session" 2>/dev/null | cat -s || echo "No preview available"
else
    echo "No session selected"
fi
