#!/usr/bin/env bash

echo "Reloading tmux-claude-status plugin..."

# Source the plugin
~/.config/tmux/plugins/tmux-claude-status/tmux-claude-status.tmux

# Show current key binding
echo "Key binding set to: C-a s"
echo "Try pressing C-a s to open the session switcher"

# Test if it works directly
echo ""
echo "Testing direct execution..."
if ~/.config/tmux/plugins/tmux-claude-status/scripts/simple-session-switcher.sh 2>&1 | head -5; then
    echo "✓ Script works"
else
    echo "✗ Script failed"
fi