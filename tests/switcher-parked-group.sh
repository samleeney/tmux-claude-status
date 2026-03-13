#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PARKED_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        case "${3:-}" in
            "#{session_name}:#{session_windows}:#{?session_attached,(attached),}")
                echo "parked-task:1:"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    list-panes)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "parked" > "$STATUS_DIR/parked-task.status"
: > "$PARKED_DIR/parked-task.parked"

switcher_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --no-fzf)"

if ! printf '%s\n' "$switcher_output" | grep -Fq "PARKED"; then
    echo "Assertion failed: switcher should render a PARKED section" >&2
    exit 1
fi
if ! printf '%s\n' "$switcher_output" | grep -Fq "[parked]"; then
    echo "Assertion failed: switcher should label parked sessions explicitly" >&2
    exit 1
fi
if printf '%s\n' "$switcher_output" | grep -Fq "[no agent]"; then
    echo "Assertion failed: parked sessions should not fall into the no-agent bucket" >&2
    exit 1
fi

echo "switcher parked grouping regression checks passed"
