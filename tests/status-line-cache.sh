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
printf '%s' "#[fg=green,bold]cached summary#[default]" > "$STATUS_DIR/.status-line"

output="$(
    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    TMUX_LOG="$LOG_FILE" \
    "$REPO_DIR/scripts/status-line.sh"
)"

if [ "$output" != "#[fg=green,bold]cached summary#[default]" ]; then
    echo "status-line cache output mismatch" >&2
    echo "Actual: $output" >&2
    exit 1
fi

if [ -f "$LOG_FILE" ]; then
    echo "status-line should not invoke tmux when collector cache is live" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "status-line cache regression checks passed"
