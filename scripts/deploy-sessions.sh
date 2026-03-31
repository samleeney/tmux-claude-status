#!/usr/bin/env bash

# Deploy multiple Claude Code agents as windows in the current tmux session
# Each window gets its own git worktree (if in a repo) and Claude instance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/claude-launcher.sh"

# --- Validation ---

manifest="$1"

if [ -z "$manifest" ]; then
    echo '{"error": "Usage: deploy-sessions.sh <manifest.json>"}' >&2
    exit 1
fi

if [ ! -f "$manifest" ]; then
    echo "{\"error\": \"Manifest not found: $manifest\"}" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo '{"error": "jq is required but not installed"}' >&2
    exit 1
fi

if ! jq empty "$manifest" 2>/dev/null; then
    echo '{"error": "Invalid JSON in manifest"}' >&2
    exit 1
fi

# --- Detect current tmux session ---

CURRENT_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
if [ -z "$CURRENT_SESSION" ] && [ -n "${TMUX_PANE:-}" ]; then
    CURRENT_SESSION=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}' 2>/dev/null || true)
fi
if [ -z "$CURRENT_SESSION" ]; then
    echo '{"error": "Not running inside a tmux session"}' >&2
    exit 1
fi

# --- Parse manifest ---

working_dir=$(jq -r '.working_directory // empty' "$manifest")
[ -z "$working_dir" ] && working_dir="$PWD"

# Resolve to absolute path
working_dir=$(cd "$working_dir" && pwd)

# Detect git repo
is_git_repo=false
if git -C "$working_dir" rev-parse --git-dir &>/dev/null; then
    is_git_repo=true
    git_root=$(git -C "$working_dir" rev-parse --show-toplevel)
fi

# Worktrees: on by default, can be disabled with "worktrees": false
use_worktrees=$(jq -r 'if .worktrees == false then "false" else "true" end' "$manifest")

session_count=$(jq '.sessions | length' "$manifest")
if [ "$session_count" -eq 0 ]; then
    echo '{"error": "No sessions in manifest"}' >&2
    exit 1
fi

# --- Helpers ---

sanitize_name() {
    # Lowercase, replace non-alnum with hyphens, collapse, trim, truncate
    echo "$1" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9-]/-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//' \
        | cut -c1-30
}

derive_name() {
    # First ~4 words of prompt, sanitized
    echo "$1" | tr '\n' ' ' | awk '{for(i=1;i<=4&&i<=NF;i++) printf "%s ", $i}' | sanitize_name
}

unique_name() {
    local base="$1"
    local name="$base"
    local suffix=2
    local existing
    existing=$(tmux list-windows -t "$CURRENT_SESSION" -F '#{window_name}' 2>/dev/null || true)

    while echo "$existing" | grep -qx "$name"; do
        name="${base}-${suffix}"
        suffix=$((suffix + 1))
    done
    echo "$name"
}

unique_branch() {
    local base="$1"
    local branch="$base"
    local suffix=2

    while git -C "$git_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; do
        branch="${base}-${suffix}"
        suffix=$((suffix + 1))
    done
    echo "$branch"
}

# --- Deploy windows ---

if [ "$is_git_repo" = true ] && [ "$use_worktrees" = "true" ]; then
    worktree_base="$git_root/.claude/worktrees"
    mkdir -p "$worktree_base"
fi

deployed=0
results="[]"
errors="[]"

for i in $(seq 0 $((session_count - 1))); do
    prompt=$(jq -r ".sessions[$i].prompt" "$manifest")
    raw_name=$(jq -r ".sessions[$i].name // empty" "$manifest")

    if [ -z "$prompt" ] || [ "$prompt" = "null" ]; then
        errors=$(echo "$errors" | jq --arg i "$i" '. + ["Session \($i): missing prompt"]')
        continue
    fi

    # Resolve window name
    if [ -n "$raw_name" ]; then
        base_name=$(sanitize_name "$raw_name")
    else
        base_name=$(derive_name "$prompt")
    fi
    [ -z "$base_name" ] && base_name="agent-$i"

    window_name=$(unique_name "$base_name")

    # Determine working directory for this window
    window_dir="$working_dir"
    branch_name=""

    if [ "$is_git_repo" = true ] && [ "$use_worktrees" = "true" ]; then
        branch_name=$(unique_branch "deploy/$window_name")
        worktree_path="$worktree_base/$window_name"

        # Handle worktree path collision
        if [ -d "$worktree_path" ]; then
            suffix=2
            while [ -d "${worktree_path}-${suffix}" ]; do
                suffix=$((suffix + 1))
            done
            worktree_path="${worktree_path}-${suffix}"
        fi

        if git -C "$git_root" worktree add "$worktree_path" -b "$branch_name" 2>/dev/null; then
            window_dir="$worktree_path"
        else
            errors=$(echo "$errors" | jq --arg n "$window_name" '. + ["Failed to create worktree for \($n)"]')
            # Fall back to working_dir
        fi
    fi

    # Write prompt to temp file
    prompt_file="/tmp/claude-deploy-prompt-${window_name}-$$.txt"
    printf '%s' "$prompt" > "$prompt_file"

    # Create window in current session and launch Claude
    tmux new-window -d -t "$CURRENT_SESSION:" -n "$window_name" -c "$window_dir"
    tmux set-option -t "$CURRENT_SESSION:$window_name" automatic-rename off
    tmux send-keys -t "$CURRENT_SESSION:$window_name" "bash '$LAUNCHER' '$prompt_file'" Enter

    deployed=$((deployed + 1))

    # Build result entry
    entry=$(jq -n \
        --arg name "$window_name" \
        --arg session "$CURRENT_SESSION" \
        --arg dir "$window_dir" \
        --arg branch "$branch_name" \
        '{name: $name, session: $session, directory: $dir, branch: (if $branch == "" then null else $branch end)}')
    results=$(echo "$results" | jq --argjson e "$entry" '. + [$e]')
done

# Clean up manifest
rm -f "$manifest"

# Output summary
jq -n \
    --argjson deployed "$deployed" \
    --arg session "$CURRENT_SESSION" \
    --argjson windows "$results" \
    --argjson errors "$errors" \
    '{deployed: $deployed, session: $session, windows: $windows, errors: (if ($errors | length) > 0 then $errors else null end)}'
