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

mkdir -p "$FAKE_BIN" "$PANE_DIR" "$WAIT_DIR" "$PARKED_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-panes)
        if [ "${2:-}" = "-t" ] && [ "${3:-}" = "repo:0" ] && [ "${4:-}" = "-F" ] && [ "${5:-}" = "#{pane_id}" ]; then
            printf '%%1\n%%2\n'
            exit 0
        fi
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "done" > "$PANE_DIR/repo_%1.status"
echo "working" > "$PANE_DIR/repo_%2.status"
echo "1" > "$WAIT_DIR/repo_%1.wait"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
bash "$REPO_DIR/scripts/park-target.sh" "repo:w0" "P"

if [ ! -f "$PARKED_DIR/repo_%1.parked" ] || [ ! -f "$PARKED_DIR/repo_%2.parked" ]; then
    echo "Assertion failed: parking a window should create parked markers for child panes" >&2
    exit 1
fi
if [ "$(cat "$PANE_DIR/repo_%1.status")" != "parked" ] || [ "$(cat "$PANE_DIR/repo_%2.status")" != "parked" ]; then
    echo "Assertion failed: parking a window should mark child pane statuses as parked" >&2
    exit 1
fi
if [ -f "$WAIT_DIR/repo_%1.wait" ]; then
    echo "Assertion failed: parking a window should clear pane wait files in that window" >&2
    exit 1
fi

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
bash "$REPO_DIR/scripts/park-target.sh" "repo:w0" "P"

if [ -f "$PARKED_DIR/repo_%1.parked" ] || [ -f "$PARKED_DIR/repo_%2.parked" ]; then
    echo "Assertion failed: toggling the same window should unpark its child panes" >&2
    exit 1
fi

echo "park target window regression checks passed"
