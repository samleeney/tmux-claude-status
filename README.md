# tmux-claude-status

See Claude AI activity across all tmux sessions at a glance.

![tmux-claude-status screenshot](claude-working-done.png)

## Install

With TPM:
```bash
set -g @plugin 'samleeney/tmux-claude-status'
```

Then add hooks to `~/.claude/settings.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh UserPromptSubmit" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh PreToolUse" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh Stop" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh Notification" }] }
    ]
  }
}
```

## Usage

| Key | Action |
|-----|--------|
| `prefix + S` | Session switcher with Claude status |
| `prefix + N` | Jump to next idle Claude session |
| `prefix + W` | Put current session in wait mode (timed snooze) |

The status bar shows `⚡ N working` / `✓ All Claudes ready` automatically.

### Keybindings

```tmux
set -g @claude-status-key "s"
set -g @claude-next-done-key "n"
set -g @claude-wait-key "w"
```

## Custom Sounds

A notification sound plays when Claude finishes. Configure with:

```tmux
set -g @claude-notification-sound "chime"
```

| Value | Description |
|-------|-------------|
| `chime` | Subtle chime (default) |
| `bell` | Classic bell |
| `fanfare` | Triumphant fanfare |
| `frog` | Comical frog ribbit |
| `speech` | TTS voice: "Claude ready" |
| `none` | Disable sounds |

Changes take effect immediately — no tmux reload needed.

## Multi-Session Deploy

Spin up parallel Claude Code sessions from within a running session. Each gets its own tmux session and git worktree for file isolation.

Use the `/deploy` skill from Claude Code, or call the script directly:

```bash
cat > /tmp/manifest.json << 'EOF'
{
  "sessions": [
    { "name": "refactor-auth", "prompt": "Refactor auth to use JWT..." },
    { "prompt": "Write tests for the API endpoints..." }
  ],
  "working_directory": "/path/to/repo"
}
EOF

bash ~/.config/tmux/plugins/tmux-claude-status/scripts/deploy-sessions.sh /tmp/manifest.json
```

Each session gets a `deploy/<name>` branch and worktree at `.claude/worktrees/<name>/`. Set `"worktrees": false` in the manifest if sessions need to collaborate on the same files. Status monitoring picks up new sessions automatically.

## SSH Sessions

Track Claude status on remote servers:

```bash
./setup-server.sh <session-name> <ssh-host>
```

This copies the hook to the remote machine and maps the hostname to your local session.

## How It Works

Uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to write status files to `~/.cache/tmux-claude-status/`. The status bar script reads these files every refresh cycle.

## License

MIT
