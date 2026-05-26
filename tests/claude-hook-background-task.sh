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
            echo "bg-task"
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

# Pipe a Stop payload (arbitrary JSON) through the hook for a given pane.
run_stop() {
    local pane_id="$1"
    local payload="$2"

    printf '%s\n' "$payload" | \
        PATH="$FAKE_BIN:$PATH" \
        HOME="$TEST_HOME" \
        TMUX="/tmp/tmux-test,4242,0" \
        TMUX_PANE="$pane_id" \
        "$REPO_DIR/hooks/better-hook.sh" "Stop"
}

RUNNING_PAYLOAD='{"hook_event_name":"Stop","background_tasks":[{"id":"btr8gibw5","type":"shell","status":"running","description":"Sleep for 25 seconds","command":"sleep 25"}],"session_crons":[]}'
EMPTY_PAYLOAD='{"hook_event_name":"Stop","background_tasks":[],"session_crons":[]}'
LEGACY_PAYLOAD='{"hook_event_name":"Stop"}'

# A Stop fired while a background task is still running must keep the agent
# working rather than flipping to done.
run_stop "%1" "$RUNNING_PAYLOAD"
assert_eq "working" "$(cat "$STATUS_DIR/bg-task.status")" "Stop with a running background task keeps the session working"
assert_eq "working" "$(cat "$PANE_DIR/bg-task_%1.status")" "Stop with a running background task keeps the pane working"

# When the task finishes Claude fires another Stop with an empty array — done.
run_stop "%1" "$EMPTY_PAYLOAD"
assert_eq "done" "$(cat "$STATUS_DIR/bg-task.status")" "Stop with no running background tasks marks the session done"
assert_eq "done" "$(cat "$PANE_DIR/bg-task_%1.status")" "Stop with no running background tasks marks the pane done"

# Older Claude versions omit background_tasks entirely — must behave as before.
run_stop "%1" "$LEGACY_PAYLOAD"
assert_eq "done" "$(cat "$STATUS_DIR/bg-task.status")" "Stop without a background_tasks field degrades to done"

echo "Claude background-task hook regression checks passed"
