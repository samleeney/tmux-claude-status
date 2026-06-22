#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
CACHE_FILE="$STATUS_DIR/.sidebar-cache"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

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
                printf 'agent-task${tab}%%1${tab}/tmp/repo${tab}300${tab}0${tab}work\n'
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

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/ps"

printf 'done' > "$PANE_DIR/agent-task_%1.status"
printf 'claude' > "$PANE_DIR/agent-task_%1.agent"

run_collector() {
    PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
        "$REPO_DIR/scripts/sidebar-collector.sh" --once
    cat "$CACHE_FILE"
}

printf 'tree' > "$STATUS_DIR/.sidebar-mode"
tree_cache="$(run_collector)"

if ! printf '%s\n' "$tree_cache" | grep -Fq "E:G|INBOX|green"; then
    echo "Assertion failed: tree mode should keep the inbox section" >&2
    printf '%s\n' "$tree_cache" >&2
    exit 1
fi

printf 'agents' > "$STATUS_DIR/.sidebar-mode"
agents_cache="$(run_collector)"

if printf '%s\n' "$agents_cache" | grep -Fq "E:G|INBOX|green"; then
    echo "Assertion failed: agents mode should suppress the inbox section" >&2
    printf '%s\n' "$agents_cache" >&2
    exit 1
fi

if ! printf '%s\n' "$agents_cache" | grep -Fq "E:G|SESSIONS|gray"; then
    echo "Assertion failed: agents mode should still render the sessions section" >&2
    printf '%s\n' "$agents_cache" >&2
    exit 1
fi

if ! printf '%s\n' "$agents_cache" | grep -Fq "P|agent-task|%1|claude|done|1"; then
    echo "Assertion failed: agents mode should expand the agent pane row" >&2
    printf '%s\n' "$agents_cache" >&2
    exit 1
fi

echo "sidebar agents mode inbox regression checks passed"
