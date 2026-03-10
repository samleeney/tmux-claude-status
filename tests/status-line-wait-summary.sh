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
        printf '%s\n' "working-session" "wait-session" "done-session"
        ;;
    list-panes)
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
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

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
    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/status-line.sh"
}

echo "working" > "$STATUS_DIR/working-session.status"
echo "wait" > "$STATUS_DIR/wait-session.status"
echo "done" > "$STATUS_DIR/done-session.status"

summary_output="$(run_status_line)"
assert_eq "#[fg=yellow,bold]⚡ agent working#[default] #[fg=cyan,bold]⏸ 1 waiting#[default] #[fg=green]✓ 1 done#[default]" "$summary_output" "wait sessions should render as a separate status-bar segment"

rm -f "$STATUS_DIR/working-session.status" "$STATUS_DIR/done-session.status"
wait_only_output="$(run_status_line)"
assert_eq "#[fg=cyan,bold]⏸ 1 waiting#[default]" "$wait_only_output" "wait-only summaries should not be reported as working"

echo "status-line wait summary regression checks passed"
