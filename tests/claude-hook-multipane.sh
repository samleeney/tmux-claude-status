#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    display-message)
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "#{session_name}" ]; then
            echo "mixed-hooks"
            exit 0
        fi
        ;;
esac

exit 1
EOF
chmod +x "$FAKE_BIN/tmux"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

run_hook() {
    local hook_name="$1"
    local pane_id="$2"

    printf '{"hook_event_name":"%s"}\n' "$hook_name" | \
        PATH="$FAKE_BIN:$PATH" \
        HOME="$TEST_HOME" \
        TMUX="/tmp/tmux-test,4242,0" \
        TMUX_PANE="$pane_id" \
        "$REPO_DIR/hooks/better-hook.sh" "$hook_name"
}

echo "working" > "$PANE_DIR/mixed-hooks_%13.status"
echo "codex" > "$PANE_DIR/mixed-hooks_%13.agent"

run_hook "Stop" "%3"
session_status="$(cat "$STATUS_DIR/mixed-hooks.status")"
claude_status="$(cat "$PANE_DIR/mixed-hooks_%3.status")"
claude_agent="$(cat "$PANE_DIR/mixed-hooks_%3.agent")"
assert_eq "working" "$session_status" "Claude finishing in one pane must not mark the whole mixed session done"
assert_eq "done" "$claude_status" "Claude Stop should mark the current pane done"
assert_eq "claude" "$claude_agent" "Claude hook should persist the pane agent name"

echo "done" > "$PANE_DIR/mixed-hooks_%13.status"
run_hook "Stop" "%3"
session_status="$(cat "$STATUS_DIR/mixed-hooks.status")"
assert_eq "done" "$session_status" "Session should become done once all tracked panes are done"

echo "Claude multi-pane hook regression checks passed"
