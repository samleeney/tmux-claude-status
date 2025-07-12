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

# 6. Add SSH session monitoring to smart-monitor.sh
echo "Adding SSH session to local monitoring..."
MONITOR_SCRIPT="$SCRIPT_DIR/smart-monitor.sh"
if [ -f "$MONITOR_SCRIPT" ]; then
    # Check if session already exists in monitor
    if ! grep -q "tmux has-session -t $SESSION_NAME" "$MONITOR_SCRIPT"; then
        # Add new session monitoring before the marker comment
        MONITOR_CODE="    # Update $SESSION_NAME status
    if tmux has-session -t $SESSION_NAME 2>/dev/null; then
        ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET \\
            $SSH_HOST \"cat ~/.cache/tmux-claude-status/${SESSION_NAME}.status\" 2>/dev/null \\
            > \"\$STATUS_DIR/${SESSION_NAME}-remote.status\" 2>/dev/null || echo \"\" > \"\$STATUS_DIR/${SESSION_NAME}-remote.status\"
    fi
    "
        # Insert before the ADD_SSH_SESSIONS_HERE marker
        awk -v code="$MONITOR_CODE" '/# ADD_SSH_SESSIONS_HERE/ {print code} {print}' "$MONITOR_SCRIPT" > "$MONITOR_SCRIPT.tmp" && mv "$MONITOR_SCRIPT.tmp" "$MONITOR_SCRIPT"
        chmod +x "$MONITOR_SCRIPT"
        echo "✓ Added $SESSION_NAME monitoring to smart-monitor.sh"
    else
        echo "✓ Session monitoring already exists"
    fi
fi

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