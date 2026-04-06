#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
LOG_FILE="$TMP_DIR/tmux.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$WAIT_DIR" "$PARKED_DIR"

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
        if [ "\${2:-}" = "-t" ] && [ "\${3:-}" = "repo" ] && [ "\${4:-}" = "-F" ] && [ "\${5:-}" = "#{pane_id}" ]; then
            printf '%%1\n%%2\n'
            exit 0
        fi
        exit 1
        ;;
    kill-session)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "working" > "$STATUS_DIR/repo.status"
echo "working" > "$STATUS_DIR/repo-remote.status"
echo "done" > "$PANE_DIR/repo_%1.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "working" > "$PANE_DIR/repo_%2.status"
echo "codex" > "$PANE_DIR/repo_%2.agent"
echo "1" > "$WAIT_DIR/repo.wait"
: > "$PARKED_DIR/repo_%2.parked"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/close-target.sh" "repo" "S"

if [ -e "$STATUS_DIR/repo.status" ] || [ -e "$STATUS_DIR/repo-remote.status" ]; then
    echo "Assertion failed: closing a session should remove session status files" >&2
    exit 1
fi
if [ -e "$PANE_DIR/repo_%1.status" ] || [ -e "$PANE_DIR/repo_%2.agent" ]; then
    echo "Assertion failed: closing a session should remove pane metadata" >&2
    exit 1
fi
if [ -e "$WAIT_DIR/repo.wait" ] || [ -e "$PARKED_DIR/repo_%2.parked" ]; then
    echo "Assertion failed: closing a session should remove wait and parked markers" >&2
    exit 1
fi
if ! grep -Fq "kill-session -t repo" "$LOG_FILE"; then
    echo "Assertion failed: close-target should kill the selected session" >&2
    exit 1
fi

echo "close target session regression checks passed"
