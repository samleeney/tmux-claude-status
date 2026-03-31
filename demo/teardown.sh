#!/usr/bin/env bash
# Removes demo sessions and cleans up status files.
# Run: ./demo/teardown.sh

STATUS_DIR="$HOME/.cache/tmux-agent-status"

# Kill fake claude processes
DEMO_DIR=$(cat /tmp/demo-agent-status-dir 2>/dev/null || echo "")
[ -n "$DEMO_DIR" ] && pkill -f "$DEMO_DIR/bin/claude" 2>/dev/null || true

# Kill demo sessions
for s in demo-api demo-wt-auth demo-wt-cache demo-frontend demo-ml demo-data demo-docs demo-ci; do
    tmux kill-session -t "$s" 2>/dev/null || true
done

# Clean status files
rm -f "$STATUS_DIR"/demo-*.status
rm -f "$STATUS_DIR"/demo-*.unread
rm -f "$STATUS_DIR"/wait/demo-*.wait
rm -f "$STATUS_DIR"/parked/demo-*.parked
rm -f "$STATUS_DIR"/panes/demo-*

# Clean temp dir
[ -n "$DEMO_DIR" ] && rm -rf "$DEMO_DIR"
rm -f /tmp/demo-agent-status-dir

# Clean keybar
rm -f /tmp/demo-keybar-fifo

echo "Demo cleaned up."
