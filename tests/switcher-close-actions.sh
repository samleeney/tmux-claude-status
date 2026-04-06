#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR"

window_actions="$("$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --close-fzf-actions "repo:w0" "P")"
pane_actions="$("$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --close-fzf-actions "repo:%1" "P")"

if [[ "$window_actions" != *"--popup-close repo:w0 P"* ]] || [[ "$window_actions" != *"+abort"* ]]; then
    echo "Assertion failed: window close actions should abort fzf and route through popup-close" >&2
    echo "$window_actions" >&2
    exit 1
fi

if [[ "$pane_actions" != *"--close repo:%1 P"* ]] || [[ "$pane_actions" != *"+reload("* ]]; then
    echo "Assertion failed: pane close actions should reload the list in place" >&2
    echo "$pane_actions" >&2
    exit 1
fi

echo "switcher close action regression checks passed"
