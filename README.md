# tmux-claude-status

See Claude AI activity across all tmux sessions at a glance.

![tmux-claude-status screenshot](claude-working-done.png)

## Features

- **Hook-based Detection** - Uses Claude Code's official hooks for accurate status
- **Visual Status** - `[⚡ working]` when Claude is processing, `[✓ done]` when idle
- **Smart Grouping** - Sessions organized by Claude status
- **Live Preview** - See session content while browsing
- **Vim Navigation** - Use `j/k` to navigate
- **SSH Support** - Detects Claude status in SSH sessions via remote status files
- **Status Bar Integration** - Shows Claude status in tmux status bar
- **Notification Sound** - Plays a sound when Claude finishes processing

## Install

### 1. Install the plugin

With TPM:
```bash
set -g @plugin 'samleeney/tmux-claude-status'
```

Manual:
```bash
git clone https://github.com/samleeney/tmux-claude-status ~/.config/tmux/plugins/tmux-claude-status
run-shell ~/.config/tmux/plugins/tmux-claude-status/tmux-claude-status.tmux
```

### 2. Set up Claude Code hooks

Add to your `~/.claude/settings.json`:
```json
{
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
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-claude-status/hooks/better-hook.sh Notification"
          }
        ]
      }
    ]
  }
}
```

## Usage

By default:
- Press `prefix + S` to open the enhanced session switcher.
- Press `prefix + N` to switch to the next 'done' project.
- Press `prefix + W` to put the current session in wait mode.

You can customize these keys in your `tmux.conf` (e.g., to restore lowercase defaults or pick other keys):

```tmux
# Session switcher key (default: S)
set -g @claude-status-key "s"

# Next done project key (default: N)
set -g @claude-next-done-key "n"

# Wait mode key (default: W)
set -g @claude-wait-key "w"
```

Defaults now use capital letters to avoid conflicts with tmux's `prefix + n` for `next-window`. Use any keys you prefer. 

### Status Bar

The plugin automatically adds Claude status to your tmux status bar:
- `✓ All Claudes ready` - All Claude instances are idle
- `⚡ N Claude(s) working` - Shows number of Claude instances currently processing

A notification sound plays when any Claude finishes processing.

### Wait Mode

Wait mode allows you to temporarily defer a session and automatically switch to the next task:

1. **Activate Wait Mode**: Press `prefix + w` in any session
2. **Set Timer**: Enter wait time in minutes (e.g., `30` for 30 minutes)
3. **Auto-Switch**: Automatically switches to next 'done' session
4. **Countdown Display**: Shows remaining time in session switcher (`prefix + s`)
5. **Status Counting**: Wait sessions count as 'working' in the status bar
6. **Auto-Expiry**: Session returns to 'done' when timer expires with notification sound
7. **Smart Cancellation**: Wait mode cancels if Claude starts working in that session

**Wait Mode Workflow:**
- Session marked as 'wait' with countdown timer
- Automatically switches to next available 'done' session
- If no 'done' sessions available, shows "✓ All done!"
- Timer counts down and displays remaining time
- When expired, session returns to 'done' status and plays notification
- If Claude starts working in the wait session, wait mode is automatically cancelled

## How It Works

The plugin uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to track status:
- `PreToolUse` - Sets status to "working" when Claude starts running tools
- `Stop` - Sets status to "done" when Claude finishes processing
- `Notification` - Sets status to "done" when Claude is waiting for user input (questions, permissions, etc.)

Status files are stored in `~/.cache/tmux-claude-status/{session_name}.status`

### SSH Sessions

To set up Claude status tracking for SSH servers, run the setup script once per server:

```bash
./setup-server.sh <session-name> <ssh-host>
```

**Example:**
```bash
./setup-server.sh reachgpu reachgpu
```

This single script:
- Maps the remote hostname to your session name
- Copies the hook to the remote server
- Sets up Claude hooks on the remote machine

After setup, use standard SSH commands:
```bash
ssh reachgpu
claude  # Status will show in your local session switcher
```

SSH sessions display as: `session-name [🌐 ssh] [⚡ working]`

## License

MIT

## Contributing

PRs welcome. Keep changes focused, add/update docs where useful, and let the CI tmux keybinding checks pass. A brief note on how you tested is appreciated.
