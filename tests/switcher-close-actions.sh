#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR"

session_actions="$("$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --close-fzf-actions "repo" "S")"
window_actions="$("$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --close-fzf-actions "repo:w0" "P")"
pane_actions="$("$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --close-fzf-actions "repo:%1" "P")"

if [[ "$session_actions" != *"--close repo S"* ]] || [[ "$session_actions" != *"+reload("* ]]; then
    echo "Assertion failed: session close actions should close directly and reload the list" >&2
    echo "$session_actions" >&2
    exit 1
fi

if [[ "$window_actions" != *"--close repo:w0 P"* ]] || [[ "$window_actions" != *"+reload("* ]]; then
    echo "Assertion failed: window close actions should close directly and reload the list" >&2
    echo "$window_actions" >&2
    exit 1
fi

if [[ "$pane_actions" != *"--close repo:%1 P"* ]] || [[ "$pane_actions" != *"+reload("* ]]; then
    echo "Assertion failed: pane close actions should reload the list in place" >&2
    echo "$pane_actions" >&2
    exit 1
fi

echo "switcher close action regression checks passed"
