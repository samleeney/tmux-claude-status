#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"

mkdir -p "$FAKE_BIN" "$STATUS_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        echo "codex-test"
        ;;
    list-panes)
        echo "4242"
        ;;
    show-option)
        if [ "${3:-}" = "@agent-notification-sound" ]; then
            echo "none"
            exit 0
        fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"

case "$args" in
    "-P 4242")
        echo "5000"
        ;;
    "-P 5000 -f codex")
        echo "5001"
        ;;
    "-P 5001")
        if [ "${PGREP_ACTIVE_WORK:-0}" = "1" ]; then
            echo "6000"
        else
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "-eo" ] || [ "${2:-}" != "pid=,ppid=,args=" ]; then
    exit 1
fi

cat <<'OUT'
4242 1 -zsh
5000 4242 node /home/test/.nvm/versions/node/v24.12.0/bin/codex
5001 5000 /home/test/.nvm/versions/node/v24.12.0/lib/node_modules/@openai/codex/vendor/codex
OUT
if [ "${PGREP_ACTIVE_WORK:-0}" = "1" ]; then
cat <<'OUT'
6000 5001 codex active task
OUT
fi
EOF
chmod +x "$FAKE_BIN/ps"

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

run_status_line() {
    local active_work="$1"

    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    PGREP_ACTIVE_WORK="$active_work" \
    "$REPO_DIR/scripts/status-line.sh"
}

echo "done" > "$STATUS_DIR/codex-test.status"
working_output="$(run_status_line 1)"
working_status="$(cat "$STATUS_DIR/codex-test.status")"
assert_eq "working" "$working_status" "active Codex work should flip status back to working"
assert_eq "#[fg=yellow,bold]⚡ agent working#[default]" "$working_output" "active Codex work should render as working"

echo "done" > "$STATUS_DIR/codex-test.status"
idle_output="$(run_status_line 0)"
idle_status="$(cat "$STATUS_DIR/codex-test.status")"
assert_eq "done" "$idle_status" "idle Codex session should stay done"
assert_eq "#[fg=green,bold]✓ All agents ready#[default]" "$idle_output" "idle Codex session should render as done"

rm -f "$STATUS_DIR/codex-test.status"
first_seen_output="$(run_status_line 0)"
first_seen_status="$(cat "$STATUS_DIR/codex-test.status")"
assert_eq "working" "$first_seen_status" "first seen Codex session should default to working"
assert_eq "#[fg=yellow,bold]⚡ agent working#[default]" "$first_seen_output" "first seen Codex session should render as working"

echo "status-line Codex regression checks passed"
