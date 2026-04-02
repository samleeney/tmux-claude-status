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
codex-multipane	%0	/home/test/project	100	0	main
codex-multipane	%4	/home/test/project	400	0	main
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
400 1 -zsh
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

echo "working" > "$PANE_DIR/codex-multipane_%0.status"
echo "done" > "$PANE_DIR/codex-multipane_%4.status"
echo "codex" > "$PANE_DIR/codex-multipane_%0.agent"
echo "codex" > "$PANE_DIR/codex-multipane_%4.agent"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
assert_contains $'PC:codex-multipane:1:1:0' "$CACHE_FILE" "multi-pane counts should include both hook-tracked panes"
assert_contains $'R:S|codex-multipane|working||\tcodex-multipane\tS' "$CACHE_FILE" "session row should stay working while any child pane is working"
assert_contains $'R:P|codex-multipane|%0|codex|working|' "$CACHE_FILE" "working pane should appear as a child sidebar row"
assert_contains $'R:P|codex-multipane|%4|codex|done|' "$CACHE_FILE" "done pane should appear as a child sidebar row"

echo "sidebar multi-pane hook status regression checks passed"
