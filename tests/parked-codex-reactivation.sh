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
                echo "parked-codex"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    list-panes)
        case "${5:-}" in
            "#{pane_pid}")
                echo "100"
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

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"

case "$args" in
    "-P 100")
        echo "101"
        ;;
    "-P 101")
        echo "102"
        ;;
    "-P 102 -f codex")
        exit 1
        ;;
    "-P 102")
        echo "103"
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
100 1 -zsh
101 100 /usr/bin/zsh
102 101 node /home/test/.nvm/versions/node/v24.12.0/bin/codex
103 102 sandbox helper
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

# Park the session — it has an active Codex with child processes (working)
echo "parked" > "$STATUS_DIR/parked-codex.status"
: > "$PARKED_DIR/parked-codex.parked"

# Status line should NOT auto-unpark — parking is an explicit user decision
status_line_output="$(run_status_line)"
status_value="$(cat "$STATUS_DIR/parked-codex.status")"
assert_eq "parked" "$status_value" "parked sessions must stay parked even when Codex is actively working"
assert_eq "" "$status_line_output" "parked sessions should not appear in status bar"

if [ ! -f "$PARKED_DIR/parked-codex.parked" ]; then
    echo "Assertion failed: parked marker must not be removed by status-line polling" >&2
    exit 1
fi

echo "parked Codex stability regression checks passed"
