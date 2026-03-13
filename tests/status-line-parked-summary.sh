#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PARKED_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        case "${3:-}" in
            "#{session_name}")
                printf '%s\n' "parked-session" "done-session"
                ;;
            *)
                exit 1
                ;;
        esac
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

echo "parked" > "$STATUS_DIR/parked-session.status"
: > "$PARKED_DIR/parked-session.parked"
echo "done" > "$STATUS_DIR/done-session.status"

summary_output="$(run_status_line)"
assert_eq "#[fg=green,bold]✓ All agents ready#[default]" "$summary_output" "parked sessions should be excluded from the status-bar summary"

rm -f "$STATUS_DIR/done-session.status"
parked_only_output="$(run_status_line)"
assert_eq "" "$parked_only_output" "parked-only sessions should render nothing in the status bar"

echo "status-line parked summary regression checks passed"
