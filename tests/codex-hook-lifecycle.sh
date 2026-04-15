#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    display-message)
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "#{session_name}" ]; then
            echo "codex-hooks"
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

    printf '{"hook_event_name":"%s"}\n' "$hook_name" | \
        PATH="$FAKE_BIN:$PATH" \
        HOME="$TEST_HOME" \
        TMUX="/tmp/tmux-test,4242,0" \
        TMUX_PANE="%9" \
        "$REPO_DIR/hooks/codex-hook.sh" "$hook_name"
}

run_hook "SessionStart"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
agent_name="$(cat "$PANE_DIR/codex-hooks_%9.agent")"
assert_eq "done" "$session_status" "SessionStart should seed the session as done"
assert_eq "done" "$pane_status" "SessionStart should seed the pane as done"
assert_eq "codex" "$agent_name" "Codex hooks should persist the pane agent name"
[ -f "$REFRESH_FILE" ] || { echo "Assertion failed: SessionStart should touch sidebar refresh marker" >&2; exit 1; }

echo "wait" > "$STATUS_DIR/codex-hooks.status"
echo "wait" > "$PANE_DIR/codex-hooks_%9.status"
echo "1" > "$WAIT_DIR/codex-hooks.wait"
echo "1" > "$WAIT_DIR/codex-hooks_%9.wait"
echo "1" > "$WAIT_DIR/codex-hooks_%10.wait"
: > "$PARKED_DIR/codex-hooks.parked"
: > "$PARKED_DIR/codex-hooks_%9.parked"
: > "$PARKED_DIR/codex-hooks_%10.parked"
run_hook "UserPromptSubmit"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "working" "$session_status" "UserPromptSubmit should mark the session working"
assert_eq "working" "$pane_status" "UserPromptSubmit should mark the pane working"
[ -f "$REFRESH_FILE" ] || { echo "Assertion failed: UserPromptSubmit should leave a sidebar refresh marker" >&2; exit 1; }
if [ -f "$WAIT_DIR/codex-hooks.wait" ]; then
    echo "Assertion failed: UserPromptSubmit should clear wait mode" >&2
    exit 1
fi
if [ -f "$PARKED_DIR/codex-hooks.parked" ]; then
    echo "Assertion failed: UserPromptSubmit should unpark the session" >&2
    exit 1
fi
if [ -f "$WAIT_DIR/codex-hooks_%9.wait" ] || [ -f "$WAIT_DIR/codex-hooks_%10.wait" ]; then
    echo "Assertion failed: UserPromptSubmit should clear per-pane wait overrides when the whole session was waiting" >&2
    exit 1
fi
if [ -f "$PARKED_DIR/codex-hooks_%9.parked" ] || [ -f "$PARKED_DIR/codex-hooks_%10.parked" ]; then
    echo "Assertion failed: UserPromptSubmit should clear per-pane parked overrides when the whole session was parked" >&2
    exit 1
fi

echo "parked" > "$PANE_DIR/codex-hooks_%9.status"
echo "1" > "$WAIT_DIR/codex-hooks_%9.wait"
: > "$PARKED_DIR/codex-hooks_%9.parked"
run_hook "UserPromptSubmit"
if [ -f "$WAIT_DIR/codex-hooks_%9.wait" ]; then
    echo "Assertion failed: UserPromptSubmit should clear the current pane wait override" >&2
    exit 1
fi
if [ -f "$PARKED_DIR/codex-hooks_%9.parked" ]; then
    echo "Assertion failed: UserPromptSubmit should clear the current pane parked override" >&2
    exit 1
fi

echo "parked" > "$STATUS_DIR/codex-hooks.status"
rm -f "$PANE_DIR/codex-hooks_%9.status"
echo "1" > "$WAIT_DIR/codex-hooks.wait"
: > "$PARKED_DIR/codex-hooks.parked"
run_hook "PreToolUse"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
assert_eq "parked" "$session_status" "PreToolUse should not unpark explicitly parked sessions"
if [ -f "$WAIT_DIR/codex-hooks.wait" ]; then
    echo "Assertion failed: PreToolUse should still clear wait mode" >&2
    exit 1
fi
if [ ! -f "$PARKED_DIR/codex-hooks.parked" ]; then
    echo "Assertion failed: PreToolUse should preserve the parked marker" >&2
    exit 1
fi

rm -f "$PARKED_DIR/codex-hooks.parked"
run_hook "Stop"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "done" "$session_status" "Stop should mark the session done"
assert_eq "done" "$pane_status" "Stop should mark the pane done"

echo "Codex hook lifecycle checks passed"
