#!/usr/bin/env bash

# Background script to update remote status without blocking session switcher

CACHE_DIR="$HOME/.cache/tmux-claude-status"
mkdir -p "$CACHE_DIR"

# Update reachgpu status in background
ssh -o ConnectTimeout=1 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET reachgpu "cat ~/.cache/tmux-claude-status/reachgpu.status" 2>/dev/null > "$CACHE_DIR/reachgpu-remote.status" &

# Don't wait for it to complete