#!/usr/bin/env bash

# Launcher for deployed Claude Code sessions
# Reads prompt from a temp file and execs claude

prompt_file="$1"

if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
    prompt=$(cat "$prompt_file")
    rm -f "$prompt_file"
    exec claude --dangerously-skip-permissions "$prompt"
else
    # No prompt file — fall back to interactive
    exec claude --dangerously-skip-permissions
fi
