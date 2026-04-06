#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
LOG_FILE="$TMP_DIR/tmux.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "\$*" >> "$LOG_FILE"

case "\${1:-}" in
    display-message)
        case "\${3:-}" in
            "#{client_session}") echo "other" ;;
            "#{window_index}") echo "9" ;;
            "#{pane_id}") echo "%99" ;;
            *) exit 1 ;;
        esac
        ;;
    list-panes)
        if [ "\${2:-}" = "-t" ] && [ "\${3:-}" = "repo:0" ] && [ "\${4:-}" = "-F" ] && [ "\${5:-}" = "#{pane_id}" ]; then
            printf '%%1\n%%2\n'
            exit 0
        fi
        exit 1
        ;;
    has-session)
        exit 0
        ;;
    kill-window)
        exit 0
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

echo "working" > "$STATUS_DIR/repo.status"
echo "done" > "$PANE_DIR/repo_%1.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "done" > "$PANE_DIR/repo_%2.status"
echo "claude" > "$PANE_DIR/repo_%2.agent"
echo "working" > "$PANE_DIR/repo_%3.status"
echo "codex" > "$PANE_DIR/repo_%3.agent"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/close-target.sh" "repo:w0" "P"

if [ -e "$PANE_DIR/repo_%1.status" ] || [ -e "$PANE_DIR/repo_%2.status" ]; then
    echo "Assertion failed: closed window pane statuses should be removed" >&2
    exit 1
fi
if [ ! -e "$PANE_DIR/repo_%3.status" ]; then
    echo "Assertion failed: panes outside the closed window should remain" >&2
    exit 1
fi

assert_eq "working" "$(cat "$STATUS_DIR/repo.status")" "remaining working pane in another window should keep the session working"
if ! grep -Fq "kill-window -t repo:0" "$LOG_FILE"; then
    echo "Assertion failed: close-target should kill the selected window" >&2
    exit 1
fi

echo "close target window regression checks passed"
