#!/usr/bin/env bash

# Single script setup for SSH server Claude status detection

if [ $# -ne 2 ]; then
    echo "Usage: $0 <session-name> <ssh-host>"
    echo "Example: $0 reachgpu reachgpu"
    echo "Sets up Claude status tracking for the specified server"
    exit 1
fi

SESSION_NAME="$1"
SSH_HOST="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Setting up Claude status tracking for: $SESSION_NAME -> $SSH_HOST"

# 1. Get the remote hostname for mapping
echo "Getting remote hostname..."
REMOTE_HOSTNAME=$(ssh "$SSH_HOST" "hostname -s" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "❌ Failed to connect to $SSH_HOST"
    exit 1
fi
echo "Remote hostname: $REMOTE_HOSTNAME"

# 2. Update local hook with the hostname mapping
echo "Updating hook with hostname mapping..."
if ! grep -q "case \$(hostname -s) in" "$SCRIPT_DIR/hooks/better-hook.sh"; then
    echo "❌ Hook file format unexpected. Please check hooks/better-hook.sh"
    exit 1
fi

# Add the hostname mapping to the case statement
if ! grep -q "$REMOTE_HOSTNAME)" "$SCRIPT_DIR/hooks/better-hook.sh"; then
    sed -i "/instance-\*) TMUX_SESSION=\"reachgpu\"/a\\                $REMOTE_HOSTNAME) TMUX_SESSION=\"$SESSION_NAME\" ;;" "$SCRIPT_DIR/hooks/better-hook.sh"
    echo "✓ Added hostname mapping: $REMOTE_HOSTNAME -> $SESSION_NAME"
else
    echo "✓ Hostname mapping already exists"
fi

# 3. Set up remote directories
echo "Setting up remote directories..."
ssh "$SSH_HOST" "mkdir -p ~/.config/tmux/plugins/tmux-claude-status/hooks ~/.claude"

# 4. Copy hook to remote
echo "Copying hook to remote..."
scp "$SCRIPT_DIR/hooks/better-hook.sh" "$SSH_HOST:~/.config/tmux/plugins/tmux-claude-status/hooks/"

# 5. Set up Claude settings on remote
echo "Setting up Claude hooks on remote..."
CLAUDE_SETTINGS='{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh Stop"
          }
        ]
      }
    ]
  }
}'

ssh "$SSH_HOST" "echo '$CLAUDE_SETTINGS' > ~/.claude/settings.json"

echo ""
echo "🎉 Setup complete!"
echo "Now when you run: ssh $SSH_HOST"
echo "And then run Claude on the remote machine,"
echo "your local session switcher will show: $SESSION_NAME [🌐 ssh] [⚡ working]"
echo ""
echo "Test it:"
echo "1. ssh $SSH_HOST"
echo "2. claude"
echo "3. Check your session switcher"