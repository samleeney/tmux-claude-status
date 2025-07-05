#!/usr/bin/env bash

echo "Testing Claude status detection..."
echo

# Test current session
current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "N/A")
echo "Current session: $current_session"

# Run status check
if [ -f ~/.config/tmux/plugins/tmux-claude-status/scripts/get-claude-status.sh ]; then
    status=$(~/.config/tmux/plugins/tmux-claude-status/scripts/get-claude-status.sh "$current_session")
    echo "Claude status: ${status:-none}"
fi

echo
echo "All tmux sessions with Claude:"
tmux list-sessions -F "#{session_name}" 2>/dev/null | while read -r session; do
    # Check for claude processes in session
    claude_found=false
    while IFS=: read -r pane_pid pane_tty; do
        if pgrep -P "$pane_pid" -f "claude" >/dev/null 2>&1; then
            claude_found=true
            break
        fi
    done < <(tmux list-panes -t "$session" -F "#{pane_pid}:#{pane_tty}" 2>/dev/null)
    
    if $claude_found; then
        status=$(~/.config/tmux/plugins/tmux-claude-status/scripts/get-claude-status.sh "$session")
        echo "  $session: ${status:-checking...}"
    fi
done

echo
echo "Status files:"
ls -la /tmp/tmux-claude-status/ 2>/dev/null || echo "No status directory yet"