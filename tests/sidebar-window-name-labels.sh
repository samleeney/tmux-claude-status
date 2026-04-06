#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        exit 0
        ;;
    list-panes)
        case "${2:-}" in
            -a)
                cat <<'OUT'
repo	%0	/home/test/repo	100	0	main
repo	%1	/home/test/repo	101	1	pr24-display-mode
repo	%2	/home/test/repo	102	2	pr25-ask-status
OUT
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
exit 1
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
101 1 -zsh
102 1 -zsh
OUT
EOF
chmod +x "$FAKE_BIN/ps"

assert_contains() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! grep -Fq "$pattern" "$file"; then
        echo "Assertion failed: $message" >&2
        echo "Missing pattern: $pattern" >&2
        echo "In file: $file" >&2
        sed -n '1,120p' "$file" >&2
        exit 1
    fi
}

echo "done" > "$PANE_DIR/repo_%1.status"
echo "done" > "$PANE_DIR/repo_%2.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "claude" > "$PANE_DIR/repo_%2.agent"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
assert_contains $'R:P|repo|%1|pr24-display-mode|done|' "$CACHE_FILE" "single-pane windows in multi-window sessions should use the window name in the session list"
assert_contains $'R:P|repo|%2|pr25-ask-status|done|' "$CACHE_FILE" "window names should be stable labels for single-pane window rows"

echo "sidebar window name label regression checks passed"
