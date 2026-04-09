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

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$WAIT_DIR" "$PARKED_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    list-sessions)
        exit 0
        ;;
    list-windows)
        if [ "\${2:-}" = "-t" ] && [ "\${4:-}" = "-F" ] && [ "\${5:-}" = "#{window_index}" ]; then
            case "\${3:-}" in
                repo)
                    printf '0\n1\n2\n'
                    ;;
                *)
                    exit 1
                    ;;
            esac
            exit 0
        fi
        exit 1
        ;;
    list-panes)
        if [ "\${2:-}" = "-a" ]; then
            printf 'repo${tab}%%1${tab}/home/test/repo${tab}101${tab}0${tab}main\n'
            printf 'repo${tab}%%2${tab}/home/test/repo${tab}102${tab}1${tab}review-a\n'
            printf 'repo${tab}%%3${tab}/home/test/repo${tab}103${tab}2${tab}review-b\n'
            exit 0
        fi

        if [ "\${2:-}" = "-t" ] && [ "\${4:-}" = "-F" ] && [ "\${5:-}" = "#{pane_id}" ]; then
            case "\${3:-}" in
                repo:0)
                    printf '%%1\n'
                    ;;
                repo:1)
                    printf '%%2\n'
                    ;;
                repo:2)
                    printf '%%3\n'
                    ;;
                *)
                    exit 1
                    ;;
            esac
            exit 0
        fi
        exit 1
        ;;
    display-message)
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

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-eo" ] && [ "${2:-}" = "pid=,ppid=" ]; then
cat <<'OUT'
101 1
102 1
103 1
OUT
    exit 0
fi

if [ "${1:-}" = "-eo" ] && [ "${2:-}" = "pid=,ppid=,args=" ]; then
cat <<'OUT'
101 1 -zsh
102 1 -zsh
103 1 -zsh
OUT
    exit 0
fi

exit 1
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
        sed -n '1,160p' "$file" >&2
        exit 1
    fi
}

assert_matches() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! grep -Eq "$pattern" "$file"; then
        echo "Assertion failed: $message" >&2
        echo "Missing regex: $pattern" >&2
        echo "In file: $file" >&2
        sed -n '1,160p' "$file" >&2
        exit 1
    fi
}

echo "done" > "$STATUS_DIR/repo.status"
echo "done" > "$PANE_DIR/repo_%1.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "done" > "$PANE_DIR/repo_%2.status"
echo "claude" > "$PANE_DIR/repo_%2.agent"
echo "working" > "$PANE_DIR/repo_%3.status"
echo "claude" > "$PANE_DIR/repo_%3.agent"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
bash "$REPO_DIR/scripts/wait-session-handler.sh" "repo:w0" "5" >/dev/null

if [ ! -f "$WAIT_DIR/repo_%1.wait" ]; then
    echo "Assertion failed: waiting one window should create child pane wait files" >&2
    exit 1
fi
if [ -f "$WAIT_DIR/repo.wait" ]; then
    echo "Assertion failed: waiting one window must not leave a session-level wait file behind" >&2
    exit 1
fi
if [ "$(cat "$STATUS_DIR/repo.status")" = "wait" ]; then
    echo "Assertion failed: waiting one window must not force the whole session status to wait" >&2
    exit 1
fi

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
assert_contains $'R:I|repo|w1|repo › review-a|done\trepo:w1\tP' "$CACHE_FILE" "waiting one window should preserve sibling done windows in the inbox"
assert_contains $'R:S|repo|working||\trepo\tS' "$CACHE_FILE" "waiting one window should keep the session working when a sibling window is still working"
assert_matches $'^R:P\\|repo\\|%1\\|main\\|wait\\|[01]\trepo:w0\tP$' "$CACHE_FILE" "waiting one window should mark only that window waiting"
assert_matches $'^R:P\\|repo\\|%2\\|review-a\\|done\\|[01]\trepo:w1\tP$' "$CACHE_FILE" "waiting one window should leave sibling done windows unchanged"
assert_matches $'^R:P\\|repo\\|%3\\|review-b\\|working\\|[01]\trepo:w2\tP$' "$CACHE_FILE" "waiting one window should leave sibling working windows unchanged"

echo "wait window scope regression checks passed"
