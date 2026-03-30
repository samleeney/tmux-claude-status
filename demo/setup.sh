#!/usr/bin/env bash
# Creates mock tmux sessions with realistic agent states for demo recording.
# Run: ./demo/setup.sh
# Teardown: ./demo/teardown.sh

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
DEMO_DIR=$(mktemp -d)
echo "$DEMO_DIR" > /tmp/demo-agent-status-dir

mkdir -p "$STATUS_DIR/parked" "$STATUS_DIR/wait" "$STATUS_DIR/panes"

# ── Fake claude binary (so pgrep detects multi-agent panes) ──
mkdir -p "$DEMO_DIR/bin"
cat > "$DEMO_DIR/bin/claude" <<'EOF'
#!/bin/sh
exec sleep infinity
EOF
chmod +x "$DEMO_DIR/bin/claude"
export PATH="$DEMO_DIR/bin:$PATH"

# ── Git repo with worktrees ──
mkdir -p "$DEMO_DIR/my-api"
cd "$DEMO_DIR/my-api"
git init -q
git commit --allow-empty -q -m "init"
mkdir -p .claude/worktrees
git worktree add -q .claude/worktrees/auth-refactor -b deploy/auth-refactor HEAD
git worktree add -q .claude/worktrees/cache-layer -b deploy/cache-layer HEAD

# ── Kill any previous demo sessions ──
for s in demo-api demo-wt-auth demo-wt-cache demo-frontend demo-ml demo-data demo-docs demo-ci; do
    tmux kill-session -t "$s" 2>/dev/null || true
done

# ── Create sessions ──

# Parent API session with 2 claude panes (multi-agent)
tmux new-session -d -s demo-api -c "$DEMO_DIR/my-api"
tmux send-keys -t demo-api "export PATH=$DEMO_DIR/bin:\$PATH && claude --dangerously-skip-permissions 2>/dev/null &" Enter
sleep 0.3
tmux split-window -h -t demo-api -c "$DEMO_DIR/my-api"
tmux send-keys -t demo-api "export PATH=$DEMO_DIR/bin:\$PATH && claude --dangerously-skip-permissions 2>/dev/null &" Enter
sleep 0.3

# Worktree sessions (children of demo-api)
tmux new-session -d -s demo-wt-auth -c "$DEMO_DIR/my-api/.claude/worktrees/auth-refactor"
tmux send-keys -t demo-wt-auth "export PATH=$DEMO_DIR/bin:\$PATH && claude --dangerously-skip-permissions 2>/dev/null &" Enter
sleep 0.3

tmux new-session -d -s demo-wt-cache -c "$DEMO_DIR/my-api/.claude/worktrees/cache-layer"
tmux send-keys -t demo-wt-cache "export PATH=$DEMO_DIR/bin:\$PATH && claude --dangerously-skip-permissions 2>/dev/null &" Enter
sleep 0.3

# Frontend — working
tmux new-session -d -s demo-frontend
tmux send-keys -t demo-frontend "echo 'Server running on localhost:3000'" Enter
sleep 0.1

# ML — done
tmux new-session -d -s demo-ml
tmux send-keys -t demo-ml "echo 'Training complete: accuracy 97.3%'" Enter
sleep 0.1

# Data — unread
tmux new-session -d -s demo-data
tmux send-keys -t demo-data "echo 'Migration complete: 1,247,832 rows'" Enter
sleep 0.1

# Docs — done
tmux new-session -d -s demo-docs
tmux send-keys -t demo-docs "echo 'README.md updated'" Enter
sleep 0.1

# CI — wait
tmux new-session -d -s demo-ci
tmux send-keys -t demo-ci "echo 'CI pipeline queued...'" Enter
sleep 0.1

# ── Write status files ──
echo "working" > "$STATUS_DIR/demo-api.status"
echo "working" > "$STATUS_DIR/demo-wt-auth.status"
echo "done"    > "$STATUS_DIR/demo-wt-cache.status"
echo "working" > "$STATUS_DIR/demo-frontend.status"
echo "done"    > "$STATUS_DIR/demo-ml.status"
echo "done"    > "$STATUS_DIR/demo-data.status"
touch "$STATUS_DIR/demo-data.unread"
echo "done"    > "$STATUS_DIR/demo-docs.status"
echo "wait"    > "$STATUS_DIR/demo-ci.status"
echo "$(( $(date +%s) + 1800 ))" > "$STATUS_DIR/wait/demo-ci.wait"

# ── Reload plugin ──
tmux source-file "$PLUGIN_DIR/tmux-agent-status.tmux" 2>/dev/null || true

# ── Keystroke display bar ──
FIFO="/tmp/demo-keybar-fifo"
rm -f "$FIFO"
mkfifo "$FIFO"

# Create a small pane at the bottom for keystroke display
tmux split-window -v -l 1 -t demo-api "$PLUGIN_DIR/demo/keybar.sh"
tmux select-pane -t demo-api:0.0  # focus back to main pane

# Install the 'k' function into the demo-api session's shell
tmux send-keys -t demo-api:0.0 "k() { echo \"\$*\" > /tmp/demo-keybar-fifo; sleep 0.3; }" Enter
sleep 0.2

echo ""
echo "Demo sessions created! States:"
echo "  UNREAD:  demo-data"
echo "  DONE:    demo-ml, demo-docs, demo-wt-cache"
echo "  WORKING: demo-api (2 panes), demo-wt-auth, demo-frontend"
echo "  WAIT:    demo-ci (30m)"
echo ""
echo "Worktree tree: demo-api → demo-wt-auth, demo-wt-cache"
echo ""
echo "Keystroke bar ready. Use:  k \"prefix + o\""
echo ""
echo "To record:  ./demo/record.sh full"
echo "To clean:   ./demo/teardown.sh"
