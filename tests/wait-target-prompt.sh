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

mkdir -p "$FAKE_BIN" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "\$*" >> "$LOG_FILE"

case "\${1:-}" in
    command-prompt)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "working" > "$PANE_DIR/repo_%1.status"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
bash "$REPO_DIR/scripts/wait-target.sh" "repo:%1" "P"

if ! grep -Fq "command-prompt -p Wait time in minutes:" "$LOG_FILE"; then
    echo "Assertion failed: wait target should open a tmux command prompt" >&2
    exit 1
fi
if ! grep -Fq 'repo:%%1' "$LOG_FILE"; then
    echo "Assertion failed: wait target should escape pane percent signs in the prompt command" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "wait target prompt regression checks passed"
