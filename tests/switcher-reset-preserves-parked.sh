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
        case "${2:-}" in
            -F)
                case "${3:-}" in
                    "#{session_name}")
                        echo "parked-task"
                        ;;
                    "#{session_name}:#{session_windows}:#{?session_attached,(attached),}")
                        echo "parked-task:1:"
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

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/pkill" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/pkill"

echo "parked" > "$STATUS_DIR/parked-task.status"
: > "$PARKED_DIR/parked-task.parked"

reset_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --reset)"

if ! printf '%s\n' "$reset_output" | grep -Fq "PARKED"; then
    echo "Assertion failed: reset output should still include the PARKED section" >&2
    exit 1
fi
if ! printf '%s\n' "$reset_output" | grep -Fq "[parked]"; then
    echo "Assertion failed: parked sessions should remain parked after reset" >&2
    exit 1
fi
if printf '%s\n' "$reset_output" | grep -Fq "[done]"; then
    echo "Assertion failed: reset should not move parked sessions into done" >&2
    exit 1
fi
if [ ! -f "$PARKED_DIR/parked-task.parked" ]; then
    echo "Assertion failed: parked marker should survive reset" >&2
    exit 1
fi

echo "switcher reset parked preservation regression checks passed"
