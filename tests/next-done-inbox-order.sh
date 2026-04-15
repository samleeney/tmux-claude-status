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

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${TMUX_LOG:-}"

case "${1:-}" in
    list-sessions)
        printf 'repo\nzeta\n'
        ;;
    list-windows)
        if [ "${2:-}" = "-t" ] && [ "${4:-}" = "-F" ] && [ "${5:-}" = "#{window_index}" ]; then
            case "${3:-}" in
                repo)
                    printf '0\n1\n2\n'
                    ;;
                zeta)
                    printf '0\n'
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
        if [ "${2:-}" = "-a" ] && [ "${3:-}" = "-F" ]; then
            case "${4:-}" in
                "#{session_name}"$'\t'"#{pane_id}"$'\t'"#{pane_current_path}"$'\t'"#{pane_pid}"$'\t'"#{window_index}"$'\t'"#{window_name}")
                    cat <<'OUT'
repo	%1	/home/test/repo	101	0	alpha
repo	%2	/home/test/repo	102	1	beta
repo	%3	/home/test/repo	103	2	gamma
zeta	%9	/home/test/zeta	109	0	delta
OUT
                    exit 0
                    ;;
                "#{session_name}"$'\t'"#{pane_id}")
                    cat <<'OUT'
repo	%1
repo	%2
repo	%3
zeta	%9
OUT
                    exit 0
                    ;;
            esac
        fi

        if [ "${2:-}" = "-t" ] && [ "${4:-}" = "-F" ] && [ "${5:-}" = "#{pane_id}" ]; then
            case "${3:-}" in
                repo:0)
                    printf '%%1\n'
                    ;;
                repo:1)
                    printf '%%2\n'
                    ;;
                repo:2)
                    printf '%%3\n'
                    ;;
                zeta:0)
                    printf '%%9\n'
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
        if [ "${2:-}" = "-p" ]; then
            case "${3:-}" in
                "#{session_name}")
                    printf '%s\n' "${CURRENT_SESSION:-repo}"
                    ;;
                "#{window_index}")
                    printf '%s\n' "${CURRENT_WINDOW:-0}"
                    ;;
                "#{pane_id}")
                    printf '%s\n' "${CURRENT_PANE:-%1}"
                    ;;
                *)
                    exit 1
                    ;;
            esac
            exit 0
        fi

        if [ -n "$log_file" ]; then
            printf '%s\n' "$*" >> "$log_file"
        fi
        exit 0
        ;;
    switch-client|select-window|select-pane)
        if [ -n "$log_file" ]; then
            printf '%s\n' "$*" >> "$log_file"
        fi
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

if [ "${1:-}" != "-eo" ] || [ "${2:-}" != "pid=,ppid=" ]; then
    exit 1
fi

cat <<'OUT'
101 1
102 1
103 1
109 1
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
        sed -n '1,160p' "$file" >&2
        exit 1
    fi
}

assert_line_order() {
    local first="$1"
    local second="$2"
    local file="$3"
    local message="$4"
    local first_line second_line

    first_line=$(grep -Fn "$first" "$file" | head -1 | cut -d: -f1)
    second_line=$(grep -Fn "$second" "$file" | head -1 | cut -d: -f1)

    if [ -z "$first_line" ] || [ -z "$second_line" ] || [ "$first_line" -ge "$second_line" ]; then
        echo "Assertion failed: $message" >&2
        sed -n '1,160p' "$file" >&2
        exit 1
    fi
}

echo "done" > "$PANE_DIR/repo_%1.status"
echo "working" > "$PANE_DIR/repo_%2.status"
echo "done" > "$PANE_DIR/repo_%3.status"
echo "done" > "$PANE_DIR/zeta_%9.status"
echo "claude" > "$PANE_DIR/repo_%1.agent"
echo "claude" > "$PANE_DIR/repo_%2.agent"
echo "claude" > "$PANE_DIR/repo_%3.agent"
echo "claude" > "$PANE_DIR/zeta_%9.agent"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
assert_contains $'R:I|repo|w0|repo › alpha|done\trepo:w0\tP' "$CACHE_FILE" "the first done window should appear in the inbox"
assert_contains $'R:I|repo|w2|repo › gamma|done\trepo:w2\tP' "$CACHE_FILE" "the second done window should appear in the inbox"
assert_contains $'R:I|zeta||zeta|done\tzeta\tS' "$CACHE_FILE" "single-agent done sessions should still appear in the inbox"
assert_line_order $'R:I|repo|w0|repo › alpha|done\trepo:w0\tP' \
    $'R:I|repo|w2|repo › gamma|done\trepo:w2\tP' \
    "$CACHE_FILE" \
    "window inbox rows should follow tmux window order"
assert_line_order $'R:I|repo|w2|repo › gamma|done\trepo:w2\tP' \
    $'R:I|zeta||zeta|done\tzeta\tS' \
    "$CACHE_FILE" \
    "sessions should follow the same inbox order used for traversal"

: > "$LOG_FILE"
PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
TMUX_LOG="$LOG_FILE" \
CURRENT_SESSION="repo" \
CURRENT_WINDOW="0" \
CURRENT_PANE="%1" \
bash "$REPO_DIR/scripts/next-done-project.sh" >/dev/null

assert_contains "switch-client -t repo" "$LOG_FILE" "next-done should stay in the same session when the next inbox item is another window"
assert_contains "select-window -t repo:2" "$LOG_FILE" "next-done should move to the next inbox window in order"

echo "next done inbox order regression checks passed"
