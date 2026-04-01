#!/usr/bin/env bash

set -euo pipefail

# Test: parked sessions with active Claude processes must stay parked.
# Regression test for the bug where status-line.sh auto-unparked sessions
# immediately after parking because it detected a running agent process.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PARKED_DIR"

# Fake tmux with a session that has an active Claude process
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        case "${3:-}" in
            "#{session_name}")
                echo "email"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    list-panes)
        case "${5:-}" in
            "#{pane_pid}")
                echo "200"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

# Claude process exists as child of shell (pid 200 -> 201 -> 202 claude)
cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"

case "$args" in
    "-P 200")
        echo "201"
        ;;
    "-P 201")
        echo "202"
        ;;
    "-P 202"*)
        exit 1
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
200 1 -zsh
201 200 node
202 201 claude --model opus
OUT
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
    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/status-line.sh"
}

# Park the email session which has an active Claude agent
echo "parked" > "$STATUS_DIR/email.status"
: > "$PARKED_DIR/email.parked"

# Run status-line multiple times to simulate polling
for i in 1 2 3; do
    run_status_line >/dev/null
done

# Session must still be parked
status_value="$(cat "$STATUS_DIR/email.status")"
assert_eq "parked" "$status_value" "parked session with active Claude must stay parked after repeated polling"

if [ ! -f "$PARKED_DIR/email.parked" ]; then
    echo "Assertion failed: parked marker must survive status-line polling" >&2
    exit 1
fi

# Status bar should show nothing (parked sessions are excluded)
final_output="$(run_status_line)"
assert_eq "" "$final_output" "parked-only sessions should produce empty status bar"

echo "parked Claude stability regression checks passed"
