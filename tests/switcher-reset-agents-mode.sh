#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
STATE_DIR="$TMP_DIR/state"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$STATE_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    list-sessions)
        if [ "\${2:-}" = "-F" ] && [ "\${3:-}" = "#{session_name}" ]; then
            echo "agent-task"
        else
            echo "agent-task"
        fi
        ;;
    list-panes)
        case "\${2:-}" in
            -a)
                printf 'agent-task${tab}%%1${tab}0${tab}work${tab}bash${tab}\n'
                ;;
            -t)
                case "\${5:-}" in
                    "#{pane_id}") echo "%1" ;;
                    "#{pane_pid}") echo "300" ;;
                    "#{pane_current_command}") echo "bash" ;;
                    *) exit 0 ;;
                esac
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-eo pid=,ppid=,args=")
        cat <<'OUT'
300 1 -zsh
301 300 claude --model opus
OUT
        ;;
    "-eo pid=,ppid=")
        cat <<'OUT'
300 1
301 300
OUT
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_BIN/ps"

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-a claude|codex")
        echo "301 claude --model opus"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/pkill" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/pkill"

printf 'done' > "$PANE_DIR/agent-task_%1.status"
printf 'claude' > "$PANE_DIR/agent-task_%1.agent"

PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --set-mode agents

reset_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --reset-rows)"

if ! printf '%s\n' "$reset_output" | grep -Fq "agent-task:0.1 [claude]"; then
    echo "Assertion failed: reset rows should keep agents-mode pane rows" >&2
    printf '%s\n' "$reset_output" >&2
    exit 1
fi

if printf '%s\n' "$reset_output" | grep -Fq "[session]"; then
    echo "Assertion failed: reset rows should not fall back to tree-mode session rows" >&2
    printf '%s\n' "$reset_output" >&2
    exit 1
fi

echo "switcher reset agents mode regression checks passed"
