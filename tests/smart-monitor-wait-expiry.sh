#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PANE_DIR="$STATUS_DIR/panes"
PID_FILE="$STATUS_DIR/smart-monitor.pid"

mkdir -p "$FAKE_BIN" "$WAIT_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        echo "local-session"
        ;;
    list-panes)
        echo "zsh"
        ;;
    show-option)
        echo "none"
        ;;
    *)
        exit 1
        ;;
esac
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

expiry_time=$(( $(date +%s) - 1 ))
echo "$expiry_time" > "$WAIT_DIR/local-session.wait"
echo "$expiry_time" > "$WAIT_DIR/local-session_%1.wait"
echo "wait" > "$STATUS_DIR/local-session.status"
echo "wait" > "$PANE_DIR/local-session_%1.status"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/smart-monitor.sh" start

for _ in 1 2 3 4 5; do
    if [ ! -f "$WAIT_DIR/local-session.wait" ]; then
        break
    fi
    sleep 1
done

if [ -f "$WAIT_DIR/local-session.wait" ]; then
    echo "Assertion failed: smart monitor should expire local wait timers without SSH sessions" >&2
    exit 1
fi

status_value="$(cat "$STATUS_DIR/local-session.status")"
assert_eq "done" "$status_value" "expired wait timers should move sessions back to done"

pane_status_value="$(cat "$PANE_DIR/local-session_%1.status")"
assert_eq "done" "$pane_status_value" "expired pane wait timers should move panes back to done"

if [ -f "$WAIT_DIR/local-session_%1.wait" ]; then
    echo "Assertion failed: smart monitor should expire pane wait timers too" >&2
    exit 1
fi

for _ in 1 2 3; do
    if [ ! -f "$PID_FILE" ]; then
        break
    fi
    sleep 1
done

if [ -f "$PID_FILE" ]; then
    echo "Assertion failed: smart monitor should exit once no SSH sessions or wait timers remain" >&2
    exit 1
fi

echo "smart-monitor wait expiry regression checks passed"
