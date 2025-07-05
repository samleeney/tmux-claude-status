# tmux-claude-status

See Claude AI activity across all tmux sessions at a glance.

![tmux-claude-status screenshot](screenshot.png)

## Features

- **Visual Status** - `[⚡ working]` when Claude is processing, `[✓ done]` when idle
- **Smart Grouping** - Sessions organized by Claude status
- **Live Preview** - See session content while browsing
- **Vim Navigation** - Use `j/k` to navigate

## Install

With TPM:
```bash
set -g @plugin 'samleeney/tmux-claude-status'
```

Manual:
```bash
git clone https://github.com/samleeney/tmux-claude-status ~/.config/tmux/plugins/tmux-claude-status
run-shell ~/.config/tmux/plugins/tmux-claude-status/tmux-claude-status.tmux
```

## Usage

Press `prefix + s` to open the enhanced session switcher.

## License

MIT