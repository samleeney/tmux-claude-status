#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
LOG_FILE="$TMP_DIR/tmux.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "tmux-called" >> "${TMUX_LOG:?}"
exit 99
EOF
chmod +x "$FAKE_BIN/tmux"

sleep 30 &
collector_pid="$!"
trap 'kill "$collector_pid" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

printf '%s\n' "$collector_pid" > "$STATUS_DIR/.sidebar-collector.pid"

run_status_line() {
    local frame="$1"

    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    TMUX_LOG="$LOG_FILE" \
    TMUX_AGENT_STATUS_FRAME="$frame" \
    "$REPO_DIR/scripts/status-line.sh"
}

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

# Two-line cache: one line per animation frame.
printf '%s\n%s\n' "frame-zero summary" "frame-one summary" > "$STATUS_DIR/.status-line"

assert_eq "frame-zero summary" "$(run_status_line 0)" "frame 0 should render the first cache line"
assert_eq "frame-one summary" "$(run_status_line 1)" "frame 1 should render the second cache line"

# Legacy single-line cache written by an older collector.
printf '%s' "#[fg=green,bold]cached summary#[default]" > "$STATUS_DIR/.status-line"
assert_eq "#[fg=green,bold]cached summary#[default]" "$(run_status_line 1)" "single-line caches should render as-is"

if [ -f "$LOG_FILE" ]; then
    echo "status-line should not invoke tmux when collector cache is live" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "status-line cache regression checks passed"
