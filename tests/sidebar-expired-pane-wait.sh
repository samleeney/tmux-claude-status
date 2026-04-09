#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$WAIT_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        printf '%s\n' "repo"
        ;;
    list-panes)
        case "${2:-}" in
            -a)
                printf 'repo\t%%1\t/home/test/repo\t100\t0\tmain\n'
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

if [ "${1:-}" != "-eo" ] || [ "${2:-}" != "pid=,ppid=" ]; then
    exit 1
fi

printf '100 1\n'
EOF
chmod +x "$FAKE_BIN/ps"

assert_contains() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! grep -Fq "$pattern" "$file"; then
        echo "Assertion failed: $message" >&2
        echo "Missing pattern: $pattern" >&2
        sed -n '1,120p' "$file" >&2
        exit 1
    fi
}

expiry_time=$(( $(date +%s) - 1 ))
echo "wait" > "$STATUS_DIR/repo.status"
echo "wait" > "$PANE_DIR/repo_%1.status"
echo "codex" > "$PANE_DIR/repo_%1.agent"
echo "$expiry_time" > "$WAIT_DIR/repo.wait"
echo "$expiry_time" > "$WAIT_DIR/repo_%1.wait"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
assert_contains $'R:S|repo|done||\trepo\tS' "$CACHE_FILE" "expired waits should return the session row to done"

pane_status_value="$(cat "$PANE_DIR/repo_%1.status")"
if [ "$pane_status_value" != "done" ]; then
    echo "Assertion failed: expired waits should return pane statuses to done" >&2
    echo "Actual pane status: $pane_status_value" >&2
    exit 1
fi

if [ -f "$WAIT_DIR/repo.wait" ] || [ -f "$WAIT_DIR/repo_%1.wait" ]; then
    echo "Assertion failed: sidebar collector should clear expired wait files" >&2
    exit 1
fi

echo "sidebar expired pane wait regression checks passed"
