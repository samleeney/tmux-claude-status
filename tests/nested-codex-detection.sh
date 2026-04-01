#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"

mkdir -p "$FAKE_BIN" "$STATUS_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        case "${3:-}" in
            "#{session_name}")
                echo "wrapped-codex"
                ;;
            "#{session_name}:#{session_windows}:#{?session_attached,(attached),}")
                echo "wrapped-codex:1:"
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

run_switcher() {
    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --no-fzf
}

status_line_output="$(run_status_line)"
status_value="$(cat "$STATUS_DIR/wrapped-codex.status")"
assert_eq "working" "$status_value" "nested shell wrappers should still be detected as Codex sessions"
assert_eq "#[fg=yellow,bold]⚡ agent working#[default]" "$status_line_output" "nested Codex sessions should render as working"

rm -f "$STATUS_DIR/wrapped-codex.status"
switcher_output="$(run_switcher)"
if ! printf '%s\n' "$switcher_output" | grep -Fq "wrapped-codex"; then
    echo "Assertion failed: switcher should include the wrapped Codex session" >&2
    exit 1
fi
if ! printf '%s\n' "$switcher_output" | grep -Fq "[done]"; then
    echo "Assertion failed: switcher should treat wrapped Codex sessions as agents, not no-agent sessions" >&2
    exit 1
fi
if printf '%s\n' "$switcher_output" | grep -Fq "[no agent]"; then
    echo "Assertion failed: wrapped Codex sessions should not fall into the no-agent bucket" >&2
    exit 1
fi

echo "nested Codex detection regression checks passed"
